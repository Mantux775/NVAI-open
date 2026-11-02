import Foundation
import Hub
@preconcurrency import MLX
@preconcurrency import MLXLMCommon
import MLXNN
import Tokenizers

// NVAI-open: derived from mlx-audio-swift's Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift.
// Kept: the model wiring, the prompt layouts (VoiceDesign/CustomVoice, x-vector clone, ICL clone),
// the talker/code-predictor loop and the weight loading. Changed (see NVAI-OPEN-CHANGES.md): synchronous
// API with a cancel closure and a seed, sampling as in the Qwen3-TTS reference (generation_config.json,
// separate sub-talker settings, min_new_tokens 2, no EOS re-insertion after top-k), decoding like the
// reference chunked_decode, text tokenizer built in memory with Qwen2's pre-tokenizer, no Hub download,
// no streaming API.

// MARK: - Sampling settings (generation_config.json)

struct Qwen3TTSSampling: Sendable {
    var doSample: Bool = true
    var temperature: Float = 0.9
    var topK: Int = 50
    var topP: Float = 1.0
    var repetitionPenalty: Float = 1.05
    var subtalkerDoSample: Bool = true
    var subtalkerTemperature: Float = 0.9
    var subtalkerTopK: Int = 50
    var subtalkerTopP: Float = 1.0
    var maxNewTokens: Int = 8192
    /// The reference passes min_new_tokens = 2 to the talker (EOS is blocked for the first two steps).
    var minNewTokens: Int = 2

    /// Reads `generation_config.json`; missing keys keep the reference's hard defaults.
    static func load(from url: URL) -> Qwen3TTSSampling {
        var s = Qwen3TTSSampling()
        guard let data = try? Data(contentsOf: url),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return s
        }
        func bool(_ key: String) -> Bool? { (dict[key] as? NSNumber)?.boolValue }
        func float(_ key: String) -> Float? { (dict[key] as? NSNumber)?.floatValue }
        func int(_ key: String) -> Int? { (dict[key] as? NSNumber)?.intValue }
        if let v = bool("do_sample") { s.doSample = v }
        if let v = float("temperature") { s.temperature = v }
        if let v = int("top_k") { s.topK = v }
        if let v = float("top_p") { s.topP = v }
        if let v = float("repetition_penalty") { s.repetitionPenalty = v }
        if let v = bool("subtalker_dosample") { s.subtalkerDoSample = v }
        if let v = float("subtalker_temperature") { s.subtalkerTemperature = v }
        if let v = int("subtalker_top_k") { s.subtalkerTopK = v }
        if let v = float("subtalker_top_p") { s.subtalkerTopP = v }
        if let v = int("max_new_tokens") { s.maxNewTokens = v }
        return s
    }
}

/// What the last generation did (token counts and timings), for logs and tests.
struct Qwen3TTSRunStats: Sendable {
    var promptLength = 0
    var textTokens = 0
    var tokenCap = 0
    var generatedTokens = 0
    var stoppedAtEOS = false
    var referenceFrames = 0
    var prepareSeconds = 0.0
    var generateSeconds = 0.0
    var decodeSeconds = 0.0
}

// MARK: - Qwen3TTS Model

final class Qwen3TTSModel: Module {
    let config: Qwen3TTSModelConfig
    let talker: Qwen3TTSTalkerForConditionalGeneration
    var speakerEncoder: Qwen3TTSSpeakerEncoder?
    var speechTokenizer: Qwen3TTSSpeechTokenizer?
    var tokenizer: Tokenizers.Tokenizer?
    var sampling = Qwen3TTSSampling()

    /// Last reference recording (Base): its x-vector and speech codes, reused while the same samples come in.
    private var cachedReferenceSamples: [Float]?
    private var cachedSpeakerEmbedding: MLXArray?
    private var cachedReferenceCodes: MLXArray?

    var sampleRate: Int { config.sampleRate }

    /// Frame cap per text token (see the generation loop).
    static let framesPerTextToken = 8

    init(config: Qwen3TTSModelConfig) {
        let talkerConfig = config.talkerConfig ?? {
            let json = "{}".data(using: .utf8)!
            return try! JSONDecoder().decode(Qwen3TTSTalkerConfig.self, from: json)
        }()
        self.config = config
        self.talker = Qwen3TTSTalkerForConditionalGeneration(config: talkerConfig)
        self.speakerEncoder = config.ttsModelType == "base"
            ? Qwen3TTSSpeakerEncoder(config: config.speakerEncoderConfig)
            : nil
    }

    // MARK: - Generation (NVAI-open entry point)

    /// Reference recording for the Base model: 24 kHz mono samples and, for ICL mode, its transcript.
    struct ReferenceInput {
        let samples: [Float]
        let transcript: String?
    }

    /// Generates speech and returns the 24 kHz mono waveform.
    /// - Parameters:
    ///   - instruct: voice description (VoiceDesign) or style instruction (CustomVoice), nil for Base.
    ///   - speaker: CustomVoice speaker name, nil otherwise.
    ///   - language: lower-case Qwen3-TTS language name or "auto".
    ///   - reference: Base model only; with transcript = ICL clone, without = x-vector-only clone.
    func generate(
        text: String,
        instruct: String?,
        speaker: String?,
        language: String,
        reference: ReferenceInput?,
        seed: UInt64?,
        shouldCancel: () -> Bool,
        stats: inout Qwen3TTSRunStats
    ) throws -> MLXArray {
        let state = seed.map { MLXRandom.RandomState(seed: $0) } ?? MLXRandom.RandomState()
        return try withRandomState(state) {
            try generateUnseeded(
                text: text, instruct: instruct, speaker: speaker, language: language,
                reference: reference, shouldCancel: shouldCancel, stats: &stats
            )
        }
    }

    private func generateUnseeded(
        text: String,
        instruct: String?,
        speaker: String?,
        language: String,
        reference: ReferenceInput?,
        shouldCancel: () -> Bool,
        stats: inout Qwen3TTSRunStats
    ) throws -> MLXArray {
        guard let speechTokenizer, let tokenizer, let talkerConfig = config.talkerConfig else {
            throw Qwen3TTSError.modelIncomplete("speech tokenizer, text tokenizer or talker config missing")
        }
        func checkCancel() throws {
            if shouldCancel() || Task.isCancelled { throw CancellationError() }
        }

        let prepareStart = Date()
        let inputEmbedsInit: MLXArray
        let trailingTextHidden: MLXArray
        let ttsPadEmbed: MLXArray
        var refCodes: MLXArray? = nil

        if let reference {
            let refAudio = MLXArray(reference.samples)
            let speakerEmbedding = referenceSpeakerEmbedding(reference.samples, refAudio: refAudio)
            if let transcript = reference.transcript {
                // ICL clone: transcript + reference codes in the prompt.
                guard speechTokenizer.hasEncoder else {
                    throw Qwen3TTSError.modelIncomplete("this checkpoint has no speech-tokenizer encoder")
                }
                let codes = referenceCodes(reference.samples, refAudio: refAudio)
                let conditioning = makeReferenceConditioning(
                    refCodes: codes, refText: transcript, speakerEmbedding: speakerEmbedding, language: language
                )
                let prepared = try prepareICLGenerationInputs(text: text, conditioning: conditioning)
                inputEmbedsInit = prepared.0
                trailingTextHidden = prepared.1
                ttsPadEmbed = prepared.2
                refCodes = prepared.3
                stats.referenceFrames = codes.dim(2)
            } else {
                // x-vector-only clone (reference: x_vector_only_mode=True): speaker embedding only.
                let prepared = prepareGenerationInputs(
                    text: text, language: language, instruct: nil, speaker: nil, speakerEmbedding: speakerEmbedding
                )
                inputEmbedsInit = prepared.0
                trailingTextHidden = prepared.1
                ttsPadEmbed = prepared.2
            }
        } else {
            let prepared = prepareGenerationInputs(
                text: text, language: language, instruct: instruct, speaker: speaker, speakerEmbedding: nil
            )
            inputEmbedsInit = prepared.0
            trailingTextHidden = prepared.1
            ttsPadEmbed = prepared.2
        }
        eval(inputEmbedsInit, trailingTextHidden, ttsPadEmbed)
        stats.prepareSeconds = Date().timeIntervalSince(prepareStart)
        stats.promptLength = inputEmbedsInit.dim(1)

        // Safety cap against a missing EOS, from the text length: 8 codec frames (0.64 s) per text token,
        // at least 75 frames (6 s), never above max_new_tokens of the generation config. Upstream used 6
        // frames per token; measured speech needed 2.8 to 4.5, slow styles need more headroom.
        let targetTokenCount = tokenizer.encode(text: text).count
        let effectiveMaxTokens = min(sampling.maxNewTokens, max(75, targetTokenCount * Self.framesPerTextToken))
        stats.textTokens = targetTokenCount
        stats.tokenCap = effectiveMaxTokens

        let startTime = Date()
        let cache = talker.makeCache()
        var generatedCodes = [MLXArray]()
        var generatedCodebookTokens = [Int]()
        let eosTokenId = talkerConfig.codecEosTokenId

        // Suppress special tokens [vocab - 1024, vocab) except EOS; EOS too during the first
        // minNewTokens steps (reference: min_new_tokens = 2).
        let suppressTokens = (talkerConfig.vocabSize - 1024 ..< talkerConfig.vocabSize)
            .filter { $0 != eosTokenId }
        let suppressTokensWithEOS = suppressTokens + [eosTokenId]

        var trailingIdx = 0
        var inputEmbeds = inputEmbedsInit
        let eosTokenArray = MLXArray([Int32(eosTokenId)]).reshaped(1, 1)
        let codeCache = talker.codePredictor.makeCache()

        for step in 0 ..< effectiveMaxTokens {
            try checkCancel()
            // Forward pass through talker
            let (logits, hidden) = talker(inputEmbeds, cache: cache)

            // Sample first codebook token
            let nextToken = sampleToken(
                logits,
                doSample: sampling.doSample,
                temperature: sampling.temperature,
                topP: sampling.topP,
                topK: sampling.topK,
                repetitionPenalty: sampling.repetitionPenalty,
                generatedTokens: generatedCodebookTokens,
                suppressTokens: step < sampling.minNewTokens ? suppressTokensWithEOS : suppressTokens
            )

            // Defer sync to the eval boundary with inputEmbeds.
            let isEOS = nextToken .== eosTokenArray

            // Generate remaining codebook tokens with code predictor
            var codeTokens = [nextToken]
            let codeHidden = hidden[0..., (-1)..., 0...]
            for layerCache in codeCache {
                layerCache.trim(layerCache.offset)
            }

            for codeIdx in 0 ..< talkerConfig.numCodeGroups - 1 {
                let codeInput: MLXArray
                if codeIdx == 0 {
                    let code0Embed = talker.getInputEmbeddings()(nextToken)
                    codeInput = concatenated([codeHidden, code0Embed], axis: 1)
                } else {
                    codeInput = talker.codePredictor.codecEmbedding[codeIdx - 1](codeTokens.last!)
                }

                let (codeLogits, _, _) = talker.codePredictor(
                    codeInput, cache: codeCache, generationStep: codeIdx
                )

                let nextCode = sampleToken(
                    codeLogits,
                    doSample: sampling.subtalkerDoSample,
                    temperature: sampling.subtalkerTemperature,
                    topP: sampling.subtalkerTopP,
                    topK: sampling.subtalkerTopK
                )
                codeTokens.append(nextCode)
            }

            let allCodes = concatenated(codeTokens, axis: 1) // [1, num_code_groups]

            // Prepare next input
            let textEmbed: MLXArray
            if trailingIdx < trailingTextHidden.dim(1) {
                textEmbed = trailingTextHidden[0..., trailingIdx ..< (trailingIdx + 1), 0...]
                trailingIdx += 1
            } else {
                textEmbed = ttsPadEmbed
            }

            // Sum all code embeddings for next step
            var codecEmbed = talker.getInputEmbeddings()(nextToken)
            for (i, code) in codeTokens.dropFirst().enumerated() {
                codecEmbed = codecEmbed + talker.codePredictor.codecEmbedding[i](code)
            }

            inputEmbeds = textEmbed + codecEmbed
            eval(inputEmbeds, isEOS, allCodes)

            let tokenId = Int(nextToken[0, 0].item(Int32.self))
            if isEOS.item(Bool.self) {
                stats.stoppedAtEOS = true
                break
            }
            generatedCodebookTokens.append(tokenId)
            generatedCodes.append(allCodes)

            if step > 0, step % 50 == 0 {
                Memory.clearCache()
            }
        }
        stats.generatedTokens = generatedCodes.count
        stats.generateSeconds = Date().timeIntervalSince(startTime)

        try checkCancel()

        guard !generatedCodes.isEmpty else {
            return MLXArray.zeros([0])
        }

        let decodeStart = Date()
        let codes = stacked(generatedCodes, axis: 1) // [1, seq_len, num_code_groups]

        var decodeCodes = codes
        if let refCodes {
            let refCodesT = refCodes.transposed(0, 2, 1)
            decodeCodes = concatenated([refCodesT, codes], axis: 1)
        }

        var audio = try decodeWaveform(decodeCodes, shouldCancel: shouldCancel)

        if let refCodes {
            // Reference: drop the part that belongs to the reference codes, proportionally.
            let refLen = refCodes.dim(2)
            let totalLen = decodeCodes.dim(1)
            let cut = Int(Double(refLen) / Double(max(totalLen, 1)) * Double(audio.dim(0)))
            if cut > 0, cut < audio.dim(0) {
                audio = audio[cut...]
            }
        }

        eval(audio)
        stats.decodeSeconds = Date().timeIntervalSince(decodeStart)
        return audio
    }

    // MARK: - Decoding

    /// Decodes codec codes [1, time, num_code_groups] to a waveform [samples] with the stateful streaming
    /// decoder (causal convolutions keep their history, the transformer its KV cache with the 72-frame
    /// window), `chunkSize` frames per step. The result equals one decode of the whole sequence, which is
    /// what the reference's chunked_decode (300 frames, 25 frames left context) computes for up to 300
    /// frames, but memory stays bounded by the chunk size. All frames are valid, nothing is trimmed.
    func decodeWaveform(
        _ codes: MLXArray, chunkSize: Int = 12, shouldCancel: () -> Bool = { false }
    ) throws -> MLXArray {
        guard let speechTokenizer else {
            throw Qwen3TTSError.modelIncomplete("speech tokenizer missing")
        }
        let decoder = speechTokenizer.decoder
        decoder.resetStreamingState()
        defer { decoder.resetStreamingState() }
        let codesT = codes.transposed(0, 2, 1) // [batch, num_quantizers, time]
        let totalTime = codesT.dim(-1)
        var wavs = [MLXArray]()
        var startIndex = 0
        while startIndex < totalTime {
            if shouldCancel() || Task.isCancelled { throw CancellationError() }
            let endIndex = min(startIndex + chunkSize, totalTime)
            let wavChunk = decoder.streamingStep(codesT[0..., 0..., startIndex ..< endIndex])
            wavs.append(wavChunk)
            Memory.clearCache()
            startIndex = endIndex
        }
        return concatenated(wavs, axis: -1).reshaped(-1)
    }

    /// Encodes a 24 kHz mono waveform to speech codes [1, 16, frames] (Base checkpoints only).
    func encodeReference(_ audio: MLXArray) -> MLXArray {
        guard let speechTokenizer else { fatalError("Speech tokenizer not loaded") }
        let codes = speechTokenizer.encode(referenceAudioForEncoder(audio))
        eval(codes)
        return codes
    }

    // MARK: - Reference handling (Base)

    private func isCachedReference(_ samples: [Float]) -> Bool {
        guard let cached = cachedReferenceSamples else { return false }
        return cached == samples
    }

    private func referenceSpeakerEmbedding(_ samples: [Float], refAudio: MLXArray) -> MLXArray? {
        if !isCachedReference(samples) {
            cachedReferenceSamples = samples
            cachedSpeakerEmbedding = nil
            cachedReferenceCodes = nil
        }
        if let cachedSpeakerEmbedding { return cachedSpeakerEmbedding }
        let embedding = extractSpeakerEmbedding(refAudio)
        if let embedding { eval(embedding) }
        cachedSpeakerEmbedding = embedding
        return embedding
    }

    private func referenceCodes(_ samples: [Float], refAudio: MLXArray) -> MLXArray {
        if !isCachedReference(samples) {
            cachedReferenceSamples = samples
            cachedSpeakerEmbedding = nil
            cachedReferenceCodes = nil
        }
        if let cachedReferenceCodes { return cachedReferenceCodes }
        let codes = encodeReference(refAudio)
        cachedReferenceCodes = codes
        return codes
    }

    private func referenceAudioForEncoder(_ refAudio: MLXArray) -> MLXArray {
        if refAudio.ndim == 1 {
            return refAudio.reshaped(1, 1, refAudio.dim(0))
        } else if refAudio.ndim == 2 {
            return refAudio.reshaped(1, refAudio.dim(0), refAudio.dim(1))
        } else {
            return refAudio
        }
    }

    private func codecEmbedIcl(from refCodes: MLXArray, talkerConfig: Qwen3TTSTalkerConfig) -> MLXArray {
        let firstCbCodes = refCodes[0..., 0, 0...]
        var refCodecEmbed = talker.getInputEmbeddings()(firstCbCodes)
        if talkerConfig.numCodeGroups > 1 {
            for i in 0 ..< (talkerConfig.numCodeGroups - 1) {
                let codeIdx = i + 1
                if codeIdx >= refCodes.dim(1) { break }
                let cbCodes = refCodes[0..., codeIdx, 0...]
                refCodecEmbed = refCodecEmbed + talker.codePredictor.codecEmbedding[i](cbCodes)
            }
        }

        let codecBosEmbed = talker.getInputEmbeddings()(
            MLXArray([Int32(talkerConfig.codecBosId)]).reshaped(1, 1)
        )
        return concatenated([codecBosEmbed, refCodecEmbed], axis: 1)
    }

    static func parseCustomVoicePrompt(_ voice: String?) -> (speaker: String, instruction: String?)? {
        guard let voice = voice?.trimmingCharacters(in: .whitespacesAndNewlines),
              !voice.isEmpty else {
            return nil
        }

        guard let commaIndex = voice.firstIndex(of: ",") else {
            return (speaker: voice, instruction: nil)
        }

        let speaker = voice[..<commaIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let instructionStart = voice.index(after: commaIndex)
        let instruction = voice[instructionStart...].trimmingCharacters(in: .whitespacesAndNewlines)

        guard !speaker.isEmpty else {
            return (speaker: voice, instruction: nil)
        }

        return (
            speaker: String(speaker),
            instruction: instruction.isEmpty ? nil : String(instruction)
        )
    }

    // MARK: - Reference conditioning

    struct Qwen3TTSReferenceConditioning {
        let speakerEmbedding: MLXArray?
        let referenceSpeechCodes: MLXArray
        let referenceTextTokenIDs: MLXArray
        let resolvedLanguage: String
        let codecLanguageID: Int?
    }

    private func makeReferenceConditioning(
        refCodes: MLXArray,
        refText: String,
        speakerEmbedding: MLXArray?,
        language: String
    ) -> Qwen3TTSReferenceConditioning {
        guard let tokenizer, let talkerConfig = config.talkerConfig else {
            fatalError("Tokenizer/config not loaded")
        }

        let resolvedLanguage = language.lowercased() == "auto" ? "auto" : language.lowercased()

        // Reference text tokenization
        let refChatText = "<|im_start|>assistant\n\(refText)<|im_end|>\n"
        let refIds = MLXArray(tokenizer.encode(text: refChatText).map { Int32($0) }).reshaped(1, -1)
        let refCount = refIds.dim(1)
        let refStart = min(3, refCount)
        let refEnd = max(refStart, refCount - 2)
        let refTextIds = refIds[0..., refStart ..< refEnd]

        // Language ID
        var languageId: Int?
        if resolvedLanguage != "auto", let langMap = talkerConfig.codecLanguageId {
            languageId = langMap[resolvedLanguage]
        }

        return Qwen3TTSReferenceConditioning(
            speakerEmbedding: speakerEmbedding,
            referenceSpeechCodes: refCodes,
            referenceTextTokenIDs: refTextIds,
            resolvedLanguage: resolvedLanguage,
            codecLanguageID: languageId
        )
    }

    func prepareICLGenerationInputs(
        text: String,
        conditioning: Qwen3TTSReferenceConditioning
    ) throws -> (MLXArray, MLXArray, MLXArray, MLXArray) {
        guard let tokenizer, let talkerConfig = config.talkerConfig else {
            throw Qwen3TTSError.modelIncomplete("text tokenizer or talker config missing")
        }

        let targetChatText = "<|im_start|>assistant\n\(text)<|im_end|>\n<|im_start|>assistant\n"
        let targetIds = MLXArray(tokenizer.encode(text: targetChatText).map { Int32($0) }).reshaped(1, -1)
        let targetCount = targetIds.dim(1)
        let targetStart = min(3, targetCount)
        let targetEnd = max(targetStart, targetCount - 5)
        let targetTextIds = targetIds[0..., targetStart ..< targetEnd]

        let ttsTokens = MLXArray(
            [Int32(config.ttsBosTokenId), Int32(config.ttsEosTokenId), Int32(config.ttsPadTokenId)]
        ).reshaped(1, 3)
        let ttsEmbeds = talker.textProjection(talker.getTextEmbeddings()(ttsTokens))
        let ttsBosEmbed = ttsEmbeds[0..., 0 ..< 1, 0...]
        let ttsEosEmbed = ttsEmbeds[0..., 1 ..< 2, 0...]
        let ttsPadEmbed = ttsEmbeds[0..., 2 ..< 3, 0...]

        let combinedTextIds = concatenated([conditioning.referenceTextTokenIDs, targetTextIds], axis: 1)
        var textEmbed = talker.textProjection(talker.getTextEmbeddings()(combinedTextIds))
        textEmbed = concatenated([textEmbed, ttsEosEmbed], axis: 1)
        let textLen = textEmbed.dim(1)

        let refCodes = conditioning.referenceSpeechCodes
        let codecEmbedIcl = codecEmbedIcl(from: refCodes, talkerConfig: talkerConfig)

        let codecPadEmbed = talker.getInputEmbeddings()(
            MLXArray([Int32(talkerConfig.codecPadId)]).reshaped(1, 1)
        )
        let textWithCodecPad = textEmbed + broadcast(
            codecPadEmbed,
            to: [1, textLen, codecPadEmbed.dim(-1)]
        )
        let codecWithTextPad = codecEmbedIcl + broadcast(
            ttsPadEmbed,
            to: [1, codecEmbedIcl.dim(1), ttsPadEmbed.dim(-1)]
        )

        let iclInputEmbed = concatenated([textWithCodecPad, codecWithTextPad], axis: 1)
        let trailingTextHidden = ttsPadEmbed

        let codecPrefill: [Int32] = if let langId = conditioning.codecLanguageID {
            [
                Int32(talkerConfig.codecThinkId),
                Int32(talkerConfig.codecThinkBosId),
                Int32(langId),
                Int32(talkerConfig.codecThinkEosId)
            ]
        } else {
            [
                Int32(talkerConfig.codecNothinkId),
                Int32(talkerConfig.codecThinkBosId),
                Int32(talkerConfig.codecThinkEosId)
            ]
        }

        var codecPrefixEmbed = talker.getInputEmbeddings()(MLXArray(codecPrefill).reshaped(1, -1))
        let codecPrefixSuffix = talker.getInputEmbeddings()(
            MLXArray([Int32(talkerConfig.codecPadId), Int32(talkerConfig.codecBosId)]).reshaped(1, 2)
        )
        if let speakerEmbedding = conditioning.speakerEmbedding {
            // The speaker encoder returns float32; keep the prompt in the talker's dtype.
            let speakerEmbed = speakerEmbedding.reshaped(1, 1, -1).asType(codecPrefixEmbed.dtype)
            codecPrefixEmbed = concatenated([codecPrefixEmbed, speakerEmbed, codecPrefixSuffix], axis: 1)
        } else {
            codecPrefixEmbed = concatenated([codecPrefixEmbed, codecPrefixSuffix], axis: 1)
        }

        let roleEmbed = talker.textProjection(talker.getTextEmbeddings()(targetIds[0..., 0 ..< 3]))

        let padCount = codecPrefixEmbed.dim(1) - 2
        let padEmbeds = broadcast(ttsPadEmbed, to: [1, padCount, ttsPadEmbed.dim(-1)])
        var combinedPrefix = concatenated([padEmbeds, ttsBosEmbed], axis: 1)
        combinedPrefix = combinedPrefix + codecPrefixEmbed[0..., 0 ..< (codecPrefixEmbed.dim(1) - 1), 0...]

        let inputEmbeds = concatenated([roleEmbed, combinedPrefix, iclInputEmbed], axis: 1)

        return (inputEmbeds, trailingTextHidden, ttsPadEmbed, refCodes)
    }

    func extractSpeakerEmbedding(_ refAudio: MLXArray) -> MLXArray? {
        guard let speakerEncoder else { return nil }

        let rawAudio: MLXArray
        if refAudio.ndim == 1 {
            rawAudio = refAudio.reshaped(1, refAudio.dim(0))
        } else if refAudio.ndim == 2 {
            if refAudio.dim(0) == 1 {
                rawAudio = refAudio
            } else {
                rawAudio = refAudio[0 ..< 1]
            }
        } else if refAudio.ndim == 3, refAudio.dim(1) == 1 {
            let squeezed = refAudio[0..., 0...]
            if squeezed.dim(0) == 1 {
                rawAudio = squeezed
            } else {
                rawAudio = squeezed[0 ..< 1]
            }
        } else {
            return nil
        }

        let batchSize = rawAudio.dim(0)
        var mels = [MLXArray]()
        mels.reserveCapacity(batchSize)

        for batch in 0 ..< batchSize {
            let waveform = rawAudio[batch]
            let mel = speakerEncoderMelSpectrogram(waveform, sampleRate: speakerEncoder.config.sampleRate)
            mels.append(mel)
        }

        let stackedMels = stacked(mels, axis: 0)
        let embedding = speakerEncoder(stackedMels)
        return embedding
    }

    /// Prefill all text using Qwen's default CustomVoice / VoiceDesign layout (reference:
    /// non_streaming_mode=True). Also used for the x-vector-only clone, with the speaker embedding.
    func prepareGenerationInputs(
        text: String,
        language: String,
        instruct: String?,
        speaker: String? = nil,
        speakerEmbedding: MLXArray? = nil
    ) -> (MLXArray, MLXArray, MLXArray) {
        guard let tokenizer, let talkerConfig = config.talkerConfig else {
            fatalError("Tokenizer/config not loaded")
        }

        // Tokenize text with ChatML template
        let chatText = "<|im_start|>assistant\n\(text)<|im_end|>\n<|im_start|>assistant\n"
        let inputIds = MLXArray(tokenizer.encode(text: chatText).map { Int32($0) }).reshaped(1, -1)

        // Get text embeddings
        let textEmbed = talker.textProjection(talker.getTextEmbeddings()(inputIds))

        // TTS special tokens
        let ttsTokens = MLXArray(
            [Int32(config.ttsBosTokenId), Int32(config.ttsEosTokenId), Int32(config.ttsPadTokenId)]
        ).reshaped(1, 3)
        let ttsEmbeds = talker.textProjection(talker.getTextEmbeddings()(ttsTokens))
        let ttsBosEmbed = ttsEmbeds[0..., 0 ..< 1, 0...]
        let ttsEosEmbed = ttsEmbeds[0..., 1 ..< 2, 0...]
        let ttsPadEmbed = ttsEmbeds[0..., 2 ..< 3, 0...]

        // Language ID — may be overridden by speaker dialect below
        var languageId: Int?
        if language.lowercased() != "auto", let langMap = talkerConfig.codecLanguageId {
            languageId = langMap[language.lowercased()]
        }

        // Speaker embedding: x-vector from reference audio (Base models), else CustomVoice speaker id
        var speakerEmbed: MLXArray? = speakerEmbedding
        if speakerEmbed == nil, let speaker = speaker {
            if let spkIdMap = talkerConfig.spkId,
               let spkIdValue = spkIdMap[speaker.lowercased()] {
                let spkIdArray = MLXArray([Int32(spkIdValue.intValue)]).reshaped(1, 1)
                speakerEmbed = talker.getInputEmbeddings()(spkIdArray)
            }
            // Reference: the dialect replaces the language only for Chinese or Auto.
            let lang = language.lowercased()
            if lang == "chinese" || lang == "auto",
               let dialectMap = talkerConfig.spkIsDialect,
               let dialectVal = dialectMap[speaker.lowercased()],
               dialectVal.isDialect,
               let dialectName = dialectVal.dialectName,
               let langMap = talkerConfig.codecLanguageId,
               let dialectLangId = langMap[dialectName] {
                languageId = dialectLangId
            }
        }

        // Build codec prefix
        let codecPrefill: [Int32] = if let langId = languageId {
            [
                Int32(talkerConfig.codecThinkId),
                Int32(talkerConfig.codecThinkBosId),
                Int32(langId),
                Int32(talkerConfig.codecThinkEosId)
            ]
        } else {
            [
                Int32(talkerConfig.codecNothinkId),
                Int32(talkerConfig.codecThinkBosId),
                Int32(talkerConfig.codecThinkEosId)
            ]
        }

        var codecEmbed = talker.getInputEmbeddings()(MLXArray(codecPrefill).reshaped(1, -1))
        let codecEmbedSuffix = talker.getInputEmbeddings()(
            MLXArray([Int32(talkerConfig.codecPadId), Int32(talkerConfig.codecBosId)]).reshaped(1, 2)
        )
        if let spkEmbed = speakerEmbed {
            codecEmbed = concatenated(
                [codecEmbed, spkEmbed.reshaped([1, 1, -1]).asType(codecEmbed.dtype), codecEmbedSuffix], axis: 1)
        } else {
            codecEmbed = concatenated([codecEmbed, codecEmbedSuffix], axis: 1)
        }

        // Instruction embedding
        var instructEmbed: MLXArray?
        if let instruct, !instruct.isEmpty {
            let instructText = "<|im_start|>user\n\(instruct)<|im_end|>\n"
            let instructIds = MLXArray(tokenizer.encode(text: instructText).map { Int32($0) }).reshaped(1, -1)
            instructEmbed = talker.textProjection(talker.getTextEmbeddings()(instructIds))
        }

        // Role embedding (first 3 tokens: <|im_start|>assistant\n)
        let roleEmbed = textEmbed[0..., ..<3, 0...]

        // Build pad/bos prefix
        let padCount = codecEmbed.dim(1) - 2
        let padEmbeds = broadcast(ttsPadEmbed, to: [1, padCount, ttsPadEmbed.dim(-1)])
        var combinedEmbed = concatenated([padEmbeds, ttsBosEmbed], axis: 1)
        combinedEmbed = combinedEmbed + codecEmbed[0..., ..<(-1), 0...]

        // Full input embedding
        var inputEmbeds: MLXArray = if let instructEmbed {
            concatenated([instructEmbed, roleEmbed, combinedEmbed], axis: 1)
        } else {
            concatenated([roleEmbed, combinedEmbed], axis: 1)
        }

        // Pair all text and EOS with codec_pad, then start audio with tts_pad + codec_bos.
        let textAll = concatenated(
            [textEmbed[0..., 3 ..< (textEmbed.dim(1) - 5), 0...], ttsEosEmbed],
            axis: 1
        )
        let textWithCodecPad = textAll + codecEmbedSuffix[0..., 0 ..< 1, 0...]
        let bosStep = ttsPadEmbed + codecEmbedSuffix[0..., 1 ..< 2, 0...]
        inputEmbeds = concatenated([inputEmbeds, textWithCodecPad, bosStep], axis: 1)

        return (inputEmbeds, ttsPadEmbed, ttsPadEmbed)
    }

    // MARK: - Token sampling (reference order: penalties, suppression, temperature, top-k, top-p)

    func sampleToken(
        _ logits: MLXArray,
        doSample: Bool = true,
        temperature: Float = 0.9,
        topP: Float = 1.0,
        topK: Int = 50,
        repetitionPenalty: Float = 1.0,
        generatedTokens: [Int]? = nil,
        suppressTokens: [Int]? = nil
    ) -> MLXArray {
        // The reference samples from float32 logits.
        var logitsSlice = logits[0..., (-1)..., 0...].squeezed(axis: 1).asType(.float32) // [batch, vocab_size]

        // Suppress tokens by setting to -inf
        if let suppress = suppressTokens, !suppress.isEmpty {
            let suppressArr = MLXArray(suppress.map { Int32($0) }).reshaped(1, -1)
            let negInf = MLXArray.full([1, suppress.count], values: MLXArray(-Float.infinity), dtype: logitsSlice.dtype)
            logitsSlice = putAlong(logitsSlice, suppressArr, values: negInf, axis: -1)
        }

        // Repetition penalty over all generated tokens (HF RepetitionPenaltyLogitsProcessor)
        if let tokens = generatedTokens, !tokens.isEmpty, repetitionPenalty != 1.0 {
            let unique = Array(Set(tokens)).filter { $0 < logitsSlice.dim(-1) }.sorted()
            if !unique.isEmpty {
                let tokenIds = MLXArray(unique.map { Int32($0) }).reshaped(1, -1)
                let selected = takeAlong(logitsSlice, tokenIds, axis: -1)
                let penalized = which(
                    selected .< 0,
                    selected * repetitionPenalty,
                    selected / repetitionPenalty
                )
                logitsSlice = putAlong(logitsSlice, tokenIds, values: penalized, axis: -1)
            }
        }

        // Greedy without sampling
        if !doSample || temperature <= 0 {
            return argMax(logitsSlice, axis: -1, keepDims: true)
        }

        var filteredLogits = logitsSlice / temperature

        // Top-k (mlx_lm.apply_top_k semantics)
        let vocabSize = filteredLogits.dim(-1)
        if topK > 0, topK < vocabSize {
            let maskIdx = argPartition(-filteredLogits, kth: topK - 1, axis: -1)[0..., topK...]
            let negInf = MLXArray.full(maskIdx.shape, values: MLXArray(-Float.infinity), dtype: filteredLogits.dtype)
            filteredLogits = putAlong(filteredLogits, maskIdx, values: negInf, axis: -1)
        }

        // Top-p (nucleus), HF TopPLogitsWarper: drop tokens whose ascending cumulative probability <= 1 - top_p
        if topP > 0, topP < 1.0 {
            let probs = softmax(filteredLogits, axis: -1)
            let sortedIndices = argSort(filteredLogits, axis: -1)
            let sortedProbs = takeAlong(probs, sortedIndices, axis: -1)
            let cumProbs = cumsum(sortedProbs, axis: -1)
            let arangeIndices = MLXArray(0 ..< vocabSize).reshaped(1, -1).asType(Int32.self)
            let zeros = MLXArray.zeros(sortedIndices.shape, type: Int32.self)
            let inverseIndices = putAlong(zeros, sortedIndices, values: arangeIndices, axis: -1)
            let cumProbsOrigOrder = takeAlong(cumProbs, inverseIndices, axis: -1)
            let mask = cumProbsOrigOrder .> (1.0 - topP)
            let negInf = MLXArray.full(filteredLogits.shape, values: MLXArray(-Float.infinity), dtype: filteredLogits.dtype)
            filteredLogits = which(mask, filteredLogits, negInf)
        }

        let token = categorical(filteredLogits)
        return token.reshaped(1, 1)
    }

    // MARK: - Loading from a local model folder

    static func fromModelDirectory(_ modelDir: URL) throws -> Qwen3TTSModel {
        let fm = FileManager.default
        let configURL = modelDir.appendingPathComponent("config.json")
        guard fm.fileExists(atPath: configURL.path) else {
            throw Qwen3TTSError.missingFile("config.json")
        }
        let configData = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(Qwen3TTSModelConfig.self, from: configData)
        guard config.modelType == "qwen3_tts" else {
            throw Qwen3TTSError.unsupportedModel("model_type \(config.modelType)")
        }
        guard config.tokenizerType == "qwen3_tts_tokenizer_12hz" else {
            throw Qwen3TTSError.unsupportedModel("tokenizer_type \(config.tokenizerType) (only the 12 Hz tokenizer)")
        }
        guard config.talkerConfig != nil else {
            throw Qwen3TTSError.unsupportedModel("config.json has no talker_config")
        }

        let model = Qwen3TTSModel(config: config)
        model.sampling = Qwen3TTSSampling.load(from: modelDir.appendingPathComponent("generation_config.json"))

        // Load talker (and speaker encoder) weights
        var allWeights = [String: MLXArray]()
        let modelFiles = try fm.contentsOfDirectory(at: modelDir, includingPropertiesForKeys: nil)
        for file in modelFiles where file.pathExtension == "safetensors" {
            let weights = try MLX.loadArrays(url: file)
            allWeights.merge(weights) { _, new in new }
        }
        guard !allWeights.isEmpty else {
            throw Qwen3TTSError.missingFile("model.safetensors")
        }

        // Sanitize and load talker weights
        let talkerWeights = Qwen3TTSTalkerForConditionalGeneration.sanitize(weights: allWeights)
        let talkerPairs = talkerWeights.map { ($0.key, $0.value) }

        // Quantized checkpoints store packed weights and companion .scales tensors.
        // Convert talker Linear layers before loading those tensors.
        if config.quantization != nil || config.perLayerQuantization != nil {
            quantize(model: model.talker) { path, _ in
                guard talkerWeights["\(path).scales"] != nil else {
                    return nil
                }

                if let perLayerQuant = config.perLayerQuantization,
                   let layerQuant = perLayerQuant.quantization(layer: path) {
                    return layerQuant.asTuple
                }

                return config.quantization?.asTuple
            }
        }

        try model.talker.update(parameters: ModuleParameters.unflattened(talkerPairs), verify: .all)
        eval(model.talker.parameters())

        // Text tokenizer (Qwen2 BPE), built in memory: the repos ship vocab.json + merges.txt only.
        model.tokenizer = try makeTextTokenizer(modelDir: modelDir)

        // Speech tokenizer
        let speechTokenizerPath = modelDir.appendingPathComponent("speech_tokenizer")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: speechTokenizerPath.path, isDirectory: &isDir), isDir.boolValue else {
            throw Qwen3TTSError.missingFile("speech_tokenizer/")
        }
        try loadSpeechTokenizer(model: model, path: speechTokenizerPath)

        // Load speaker encoder for base models
        if config.ttsModelType == "base" {
            let speakerWeights = Qwen3TTSSpeakerEncoder.sanitize(weights: allWeights)
            guard !speakerWeights.isEmpty, let speakerEncoder = model.speakerEncoder else {
                throw Qwen3TTSError.modelIncomplete("Base checkpoint without speaker_encoder weights")
            }
            let speakerPairs = speakerWeights.map { ($0.key, $0.value) }
            try speakerEncoder.update(parameters: ModuleParameters.unflattened(speakerPairs), verify: .all)
            eval(speakerEncoder.parameters())
        }

        return model
    }

    private static func loadSpeechTokenizer(model: Qwen3TTSModel, path: URL) throws {
        let configPath = path.appendingPathComponent("config.json")
        guard let configData = try? Data(contentsOf: configPath) else {
            throw Qwen3TTSError.missingFile("speech_tokenizer/config.json")
        }
        let tokenizerConfig = try JSONDecoder().decode(Qwen3TTSTokenizerConfig.self, from: configData)

        let speechTokenizer = Qwen3TTSSpeechTokenizer(config: tokenizerConfig)

        // Load weights
        var tokenizerWeights = [String: MLXArray]()
        let files = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "safetensors" {
            let weights = try MLX.loadArrays(url: file)
            tokenizerWeights.merge(weights) { _, new in new }
        }
        guard !tokenizerWeights.isEmpty else {
            throw Qwen3TTSError.missingFile("speech_tokenizer/model.safetensors")
        }

        let sanitized = Qwen3TTSSpeechTokenizer.sanitize(weights: tokenizerWeights)
        let pairs = sanitized.map { ($0.key, $0.value) }
        try speechTokenizer.update(parameters: ModuleParameters.unflattened(pairs), verify: .all)
        eval(speechTokenizer.parameters())

        model.speechTokenizer = speechTokenizer
    }

    // MARK: - Text tokenizer from vocab.json + merges.txt

    /// Qwen3-TTS repos ship a slow tokenizer (vocab.json + merges.txt) but swift-transformers needs the
    /// tokenizer.json layout. This builds that layout in memory, as in Qwen2/Qwen3's tokenizer.json:
    /// NFC normalizer, Qwen2 split regex (single digits, `\p{N}`), byte-level BPE, the added tokens from
    /// tokenizer_config.json. Nothing is written into the model folder.
    static func makeTextTokenizer(modelDir: URL) throws -> Tokenizers.Tokenizer {
        let vocabURL = modelDir.appendingPathComponent("vocab.json")
        let mergesURL = modelDir.appendingPathComponent("merges.txt")
        let tokenizerConfigURL = modelDir.appendingPathComponent("tokenizer_config.json")
        for (url, name) in [(vocabURL, "vocab.json"), (mergesURL, "merges.txt"), (tokenizerConfigURL, "tokenizer_config.json")] {
            guard FileManager.default.fileExists(atPath: url.path) else { throw Qwen3TTSError.missingFile(name) }
        }

        guard let vocab = try JSONSerialization.jsonObject(with: Data(contentsOf: vocabURL)) as? [NSString: Any] else {
            throw Qwen3TTSError.unsupportedModel("vocab.json is not a JSON object")
        }
        let mergesText = try String(contentsOf: mergesURL, encoding: .utf8)
        let mergeLines = mergesText.components(separatedBy: .newlines)
            .filter { !$0.isEmpty && !$0.hasPrefix("#version") }

        guard let tokenizerConfigDict = try JSONSerialization.jsonObject(with: Data(contentsOf: tokenizerConfigURL)) as? [NSString: Any] else {
            throw Qwen3TTSError.unsupportedModel("tokenizer_config.json is not a JSON object")
        }

        // added_tokens from tokenizer_config.json's added_tokens_decoder, sorted by id
        var addedTokens = [(Int, Config)]()
        if let decoder = tokenizerConfigDict["added_tokens_decoder"] as? [String: [String: Any]] {
            for (idString, info) in decoder {
                guard let id = Int(idString), let content = info["content"] as? String else { continue }
                func flag(_ key: String, _ fallback: Bool) -> Bool { (info[key] as? NSNumber)?.boolValue ?? fallback }
                let entry: [NSString: Config] = [
                    "id": Config(id),
                    "content": Config(content),
                    "single_word": Config(flag("single_word", false)),
                    "lstrip": Config(flag("lstrip", false)),
                    "rstrip": Config(flag("rstrip", false)),
                    "normalized": Config(flag("normalized", false)),
                    "special": Config(flag("special", true)),
                ]
                addedTokens.append((id, Config(entry)))
            }
        }
        addedTokens.sort { $0.0 < $1.0 }

        let byteLevel: [NSString: Config] = [
            "type": "ByteLevel",
            "add_prefix_space": Config(false),
            "trim_offsets": Config(false),
            "use_regex": Config(false),
        ]
        let split: [NSString: Config] = [
            "type": "Split",
            "pattern": Config([
                "Regex": Config(#"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"#)
            ] as [NSString: Config]),
            "behavior": "Isolated",
            "invert": Config(false),
        ]
        let model: [NSString: Config] = [
            "type": "BPE",
            "continuing_subword_prefix": "",
            "end_of_word_suffix": "",
            "fuse_unk": Config(false),
            "byte_fallback": Config(false),
            "ignore_merges": Config(false),
            "vocab": Config(vocab),
            "merges": Config(mergeLines.map { Config($0) }),
        ]
        let tokenizerData: [NSString: Config] = [
            "version": "1.0",
            "added_tokens": Config(addedTokens.map { $0.1 }),
            "normalizer": Config(["type": "NFC"] as [NSString: Config]),
            "pre_tokenizer": Config([
                "type": "Sequence",
                "pretokenizers": Config([Config(split), Config(byteLevel)]),
            ] as [NSString: Config]),
            "post_processor": Config(byteLevel),
            "decoder": Config(byteLevel),
            "model": Config(model),
        ]

        let tokenizerConfig = Config(configFromJSON(tokenizerConfigDict) as [NSString: Config])
        return try AutoTokenizer.from(tokenizerConfig: tokenizerConfig, tokenizerData: Config(tokenizerData))
    }

    /// JSONSerialization -> Config with booleans kept as booleans (Config's own `[NSString: Any]`
    /// initializer turns `true`/`false` into integers). `null` values are left out.
    private static func configFromJSON(_ dict: [NSString: Any]) -> [NSString: Config] {
        var out = [NSString: Config]()
        for (key, value) in dict {
            if let converted = configValue(value) { out[key] = converted }
        }
        return out
    }

    private static func configValue(_ value: Any) -> Config? {
        switch value {
        case let dict as [NSString: Any]:
            return Config(configFromJSON(dict))
        case let array as [Any]:
            return Config(array.compactMap { configValue($0) })
        case let string as String:
            return Config(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return Config(number.boolValue) }
            if CFNumberIsFloatType(number) { return Config(number.floatValue) }
            return Config(number.intValue)
        default:
            return nil
        }
    }
}
