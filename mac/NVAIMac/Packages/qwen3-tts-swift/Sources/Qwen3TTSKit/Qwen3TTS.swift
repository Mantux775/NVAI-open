// Qwen3TTSKit: Qwen3-TTS 12 Hz (VoiceDesign, Base voice clone, CustomVoice) on MLX for NVAI-open.
// Model code from Blaizzy/mlx-audio-swift (MIT), see NVAI-OPEN-CHANGES.md; this file is the
// NVAI-open front end.

import Foundation
@preconcurrency import MLX

/// Errors of `Qwen3TTS`.
public enum Qwen3TTSError: Error, LocalizedError, Equatable {
    /// A file of the model folder is missing (name relative to the folder).
    case missingFile(String)
    /// The folder holds something other than a Qwen3-TTS 12 Hz checkpoint.
    case unsupportedModel(String)
    /// A part of the model is missing or failed to load.
    case modelIncomplete(String)
    /// `design` on a Base model or `clone` on a VoiceDesign/CustomVoice model.
    case wrongModelKind(String)
    /// Language not known to the checkpoint.
    case unsupportedLanguage(String)
    /// CustomVoice speaker not known to the checkpoint.
    case unsupportedSpeaker(String)
    case emptyText
    /// Reference audio missing or shorter than `Qwen3TTS.minimumReferenceSeconds`.
    case referenceTooShort

    public var errorDescription: String? {
        switch self {
        case .missingFile(let name): return "Qwen3-TTS: file missing in the model folder: \(name)"
        case .unsupportedModel(let what): return "Qwen3-TTS: unsupported model (\(what))"
        case .modelIncomplete(let what): return "Qwen3-TTS: model incomplete (\(what))"
        case .wrongModelKind(let what): return "Qwen3-TTS: \(what)"
        case .unsupportedLanguage(let language): return "Qwen3-TTS: unsupported language \"\(language)\""
        case .unsupportedSpeaker(let speaker): return "Qwen3-TTS: unknown speaker \"\(speaker)\""
        case .emptyText: return "Qwen3-TTS: the text is empty"
        case .referenceTooShort: return "Qwen3-TTS: the reference recording is missing or too short"
        }
    }
}

/// Qwen3-TTS 12 Hz on MLX.
///
/// Load a downloaded mlx-community Qwen3-TTS folder with `load(directory:)`, then call `design` (VoiceDesign,
/// CustomVoice) or `clone` (Base). Calls are synchronous and serialized; run them off the main thread.
/// Output is mono `Float` at `sampleRate` (24 000 Hz for the 12 Hz checkpoints).
public final class Qwen3TTS: @unchecked Sendable {
    public enum Kind: String, Sendable {
        /// `tts_model_type` "voice_design": voice from a natural-language description.
        case voiceDesign
        /// `tts_model_type` "base": voice cloned from a reference recording.
        case base
        /// `tts_model_type` "custom_voice": built-in speakers with a style instruction.
        case customVoice
    }

    /// What the last `design`/`clone` call did.
    public struct RunInfo: Sendable {
        /// Codec frames generated (12.5 frames per second of audio).
        public let generatedFrames: Int
        /// Upper bound for this text (8 frames per text token, at least 75, at most max_new_tokens).
        public let frameCap: Int
        /// True if the model ended the utterance itself, false if the cap stopped it.
        public let stoppedAtEndToken: Bool
        /// Text tokens of the input text.
        public let textTokens: Int
        /// Talker prompt length in tokens.
        public let promptLength: Int
        /// Reference codec frames in the prompt (ICL clone), else 0.
        public let referenceFrames: Int
        public let prepareSeconds: Double
        public let generateSeconds: Double
        public let decodeSeconds: Double
        public let audioSeconds: Double
    }

    /// Sampling defaults read from the checkpoint's generation_config.json.
    public struct Sampling: Sendable {
        public let doSample: Bool
        public let temperature: Float
        public let topK: Int
        public let topP: Float
        public let repetitionPenalty: Float
        public let subtalkerDoSample: Bool
        public let subtalkerTemperature: Float
        public let subtalkerTopK: Int
        public let subtalkerTopP: Float
        public let maxNewTokens: Int
    }

    /// Shortest reference recording `clone` accepts.
    public static let minimumReferenceSeconds: Double = 1.0

    public let kind: Kind
    /// Output sample rate (speech tokenizer `output_sample_rate`), 24 000 Hz.
    public let sampleRate: Int
    /// Sample rate `clone` expects for the reference recording (speech tokenizer `input_sample_rate`).
    public let referenceSampleRate: Int
    /// Languages of the checkpoint as Qwen3-TTS names ("Chinese", "English", ..., "Auto").
    public let languages: [String]
    /// CustomVoice speakers (empty for VoiceDesign and Base).
    public let speakers: [String]
    public let sampling: Sampling
    /// Info about the last finished call (nil before the first one). Does not wait for a running call.
    public var lastRun: RunInfo? {
        infoLock.lock()
        defer { infoLock.unlock() }
        return _lastRun
    }

    private let model: Qwen3TTSModel
    /// Serializes generation (MLX evaluation of one model is not meant to run concurrently).
    private let lock = NSLock()
    private let infoLock = NSLock()
    private var _lastRun: RunInfo?

    /// ISO 639-1 codes accepted besides the Qwen3-TTS language names.
    private static let languageCodes: [String: String] = [
        "zh": "chinese", "en": "english", "ja": "japanese", "ko": "korean", "de": "german",
        "fr": "french", "ru": "russian", "pt": "portuguese", "es": "spanish", "it": "italian",
    ]

    private init(model: Qwen3TTSModel, kind: Kind) {
        self.model = model
        self.kind = kind
        let tokenizerConfig = model.speechTokenizer?.config
        self.sampleRate = tokenizerConfig?.outputSampleRate ?? model.sampleRate
        self.referenceSampleRate = tokenizerConfig?.inputSampleRate ?? model.sampleRate
        let languageMap = model.config.talkerConfig?.codecLanguageId ?? [:]
        self.languages = languageMap.keys
            .filter { !$0.contains("dialect") }
            .sorted()
            .map { $0.prefix(1).uppercased() + $0.dropFirst() } + ["Auto"]
        self.speakers = (model.config.talkerConfig?.spkId ?? [:]).keys.sorted()
        let s = model.sampling
        self.sampling = Sampling(
            doSample: s.doSample, temperature: s.temperature, topK: s.topK, topP: s.topP,
            repetitionPenalty: s.repetitionPenalty, subtalkerDoSample: s.subtalkerDoSample,
            subtalkerTemperature: s.subtalkerTemperature, subtalkerTopK: s.subtalkerTopK,
            subtalkerTopP: s.subtalkerTopP, maxNewTokens: s.maxNewTokens
        )
    }

    /// Loads a downloaded mlx-community Qwen3-TTS 12 Hz folder (config.json, generation_config.json,
    /// model.safetensors, vocab.json, merges.txt, tokenizer_config.json, speech_tokenizer/).
    public static func load(directory: URL) throws -> Qwen3TTS {
        let model = try Qwen3TTSModel.fromModelDirectory(directory)
        let kind: Kind
        switch model.config.ttsModelType {
        case "voice_design": kind = .voiceDesign
        case "base": kind = .base
        case "custom_voice": kind = .customVoice
        default: throw Qwen3TTSError.unsupportedModel("tts_model_type \(model.config.ttsModelType)")
        }
        Memory.clearCache()
        return Qwen3TTS(model: model, kind: kind)
    }

    /// Speech in a voice described in natural language (VoiceDesign).
    ///
    /// For a CustomVoice checkpoint, `instruct` is "Speaker" or "Speaker, style instruction" (speaker
    /// names in `speakers`).
    /// - Parameters:
    ///   - language: Qwen3-TTS name ("German", "English", ..., "Auto") or ISO code ("de", "en", ...).
    ///   - seed: fixed seed for reproducible sampling; nil draws a new one.
    ///   - shouldCancel: checked between generated frames; returning true throws `CancellationError`.
    public func design(
        text: String, instruct: String, language: String, seed: UInt64?, shouldCancel: () -> Bool
    ) throws -> [Float] {
        let text = try Self.cleanText(text)
        let languageName = try resolveLanguage(language)
        let trimmedInstruct = instruct.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .voiceDesign:
            return try run(
                text: text, instruct: trimmedInstruct.isEmpty ? nil : trimmedInstruct, speaker: nil,
                language: languageName, reference: nil, seed: seed, shouldCancel: shouldCancel
            )
        case .customVoice:
            guard let parsed = Qwen3TTSModel.parseCustomVoicePrompt(trimmedInstruct),
                  let match = speakers.first(where: { $0.lowercased() == parsed.speaker.lowercased() }) else {
                throw Qwen3TTSError.unsupportedSpeaker(trimmedInstruct)
            }
            return try run(
                text: text, instruct: parsed.instruction, speaker: match, language: languageName,
                reference: nil, seed: seed, shouldCancel: shouldCancel
            )
        case .base:
            throw Qwen3TTSError.wrongModelKind("design needs a VoiceDesign or CustomVoice model, this is a Base model")
        }
    }

    /// Speech in the voice of a reference recording (Base).
    ///
    /// With `referenceText` (the transcript of the recording) the reference codes and text go into the
    /// prompt (ICL mode); without it only the speaker embedding is used (`x_vector_only_mode=True`).
    /// - Parameters:
    ///   - referenceAudio: mono samples at `referenceSampleRate` (24 kHz), at least
    ///     `minimumReferenceSeconds` long.
    ///   - language: Qwen3-TTS name ("German", "English", ..., "Auto") or ISO code ("de", "en", ...).
    ///   - seed: fixed seed for reproducible sampling; nil draws a new one.
    ///   - shouldCancel: checked between generated frames; returning true throws `CancellationError`.
    public func clone(
        text: String, referenceAudio: [Float], referenceText: String?, language: String, seed: UInt64?,
        shouldCancel: () -> Bool
    ) throws -> [Float] {
        guard kind == .base else {
            throw Qwen3TTSError.wrongModelKind("clone needs a Base model, this is \(kind.rawValue)")
        }
        let text = try Self.cleanText(text)
        let languageName = try resolveLanguage(language)
        guard Double(referenceAudio.count) >= Self.minimumReferenceSeconds * Double(referenceSampleRate) else {
            throw Qwen3TTSError.referenceTooShort
        }
        let transcript = referenceText?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try run(
            text: text, instruct: nil, speaker: nil, language: languageName,
            reference: .init(samples: referenceAudio, transcript: (transcript?.isEmpty ?? true) ? nil : transcript),
            seed: seed, shouldCancel: shouldCancel
        )
    }

    /// Token ids of the Qwen2 text tokenizer (for checks and length estimates; ~4 ids per second of speech).
    public func textTokenIDs(_ text: String) -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return model.tokenizer?.encode(text: text) ?? []
    }

    // MARK: - Private

    private func run(
        text: String, instruct: String?, speaker: String?, language: String,
        reference: Qwen3TTSModel.ReferenceInput?, seed: UInt64?, shouldCancel: () -> Bool
    ) throws -> [Float] {
        lock.lock()
        defer {
            Memory.clearCache()
            lock.unlock()
        }
        var stats = Qwen3TTSRunStats()
        let audio = try model.generate(
            text: text, instruct: instruct, speaker: speaker, language: language,
            reference: reference, seed: seed, shouldCancel: shouldCancel, stats: &stats
        )
        let samples = audio.asType(.float32).asArray(Float.self)
        let info = RunInfo(
            generatedFrames: stats.generatedTokens, frameCap: stats.tokenCap, stoppedAtEndToken: stats.stoppedAtEOS,
            textTokens: stats.textTokens, promptLength: stats.promptLength, referenceFrames: stats.referenceFrames,
            prepareSeconds: stats.prepareSeconds, generateSeconds: stats.generateSeconds,
            decodeSeconds: stats.decodeSeconds, audioSeconds: Double(samples.count) / Double(sampleRate)
        )
        infoLock.lock()
        _lastRun = info
        infoLock.unlock()
        return samples
    }

    private func resolveLanguage(_ language: String) throws -> String {
        let key = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.isEmpty || key == "auto" { return "auto" }
        let name = Self.languageCodes[key] ?? key
        guard model.config.talkerConfig?.codecLanguageId?[name] != nil else {
            throw Qwen3TTSError.unsupportedLanguage(language)
        }
        return name
    }

    private static func cleanText(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Qwen3TTSError.emptyText }
        return trimmed
    }
}
