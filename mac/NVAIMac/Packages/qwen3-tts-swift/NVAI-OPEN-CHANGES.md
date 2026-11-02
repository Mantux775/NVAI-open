# Changes for NVAI-open / Änderungen für NVAI-open

Taken from [Blaizzy/mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) at commit
0dda61b29c308175e302dceef77c3bd84551e92b (2026-11-01), MIT License (see `LICENSE`). Model: Qwen3-TTS 12 Hz by the
Alibaba Qwen team, Apache-2.0; weights `mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-4bit` and
`mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit`. Reference for all checks: the official Python package
[QwenLM/Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS) at commit 022e286 and Hugging Face transformers.

mlx-audio-swift was chosen over AtomGradient/swift-qwen3-tts: it is maintained and carries many Qwen3-TTS fixes;
swift-qwen3-tts has 9 commits (last 2026-02-18) and no LICENSE file (only "MIT" in its README).

Copied:
- `Sources/MLXAudioTTS/Models/Qwen3TTS/` (Qwen3TTS.swift as `Model/Qwen3TTSModel.swift`, Qwen3TTSTalker,
  Qwen3TTSCodePredictor, Qwen3TTSConfig, Qwen3TTSSpeakerEncoder, Qwen3TTSSpeechTokenizer) into `Sources/Qwen3TTSKit`.
- `Sources/MLXAudioCodecs/Mimi/` Conv, Quantization, Seanet, Transformer (the speech-tokenizer encoder parts) into
  the separate target `Qwen3TTSMimi`, so their public names (LayerScale, SplitResidualVectorQuantizer, ...) stay
  apart from the decoder classes of the same name, as in upstream's two modules.
- `hanningWindow`, `MelScale` and `melFilters` from `Sources/MLXAudioCore/DSP.swift` into `Support/DSP.swift`
  (internal).

Changed for mlx-swift 0.31.6 (upstream needs 0.33):
- `MaterializedArray` (new in mlx-swift 0.33) replaced by `MLXArray` plus `eval`.
- MLXAudioCore's private copies of the LM helpers replaced by MLXLMCommon from mlx-swift-lm 3.31.4: `KVCache`,
  `KVCacheSimple`, `createAttentionMask`, `createCausalMask`, `BaseConfiguration`, `StringOrNumber` (upstream used
  MLXLMCommon itself until 2026-10-19). `import MLXFFT` dropped (FFT is in MLX). No other API changes were needed.

Removed: the `SpeechGenerationModel` protocol, async `generate`/`generateStream`, the streaming event types, the
Hugging Face download (`fromPretrained`), debug prints, and writing a `tokenizer.json` into the model folder.

Fixed (each checked against the reference on 2026-11-02):
- Speech-tokenizer encoder (ICL clone): the encoder transformer uses rotate-half RoPE (`TransformerConfig.ropeTraditional`
  is new, default true keeps Mimi's behaviour; Qwen3-TTS sets false). The checkpoint holds Hugging Face Mimi weights;
  mlx-audio's Python port also sets `rope_traditional=False`. With the fix the codes equal transformers' `MimiModel`
  in 110 of 111 and 49 of 49 frames over all 16 codebooks; upstream's interleaved RoPE matched codebook 0 in only
  29 % and 39 % of the frames, so the ICL prompt got largely wrong reference codes.
- Speech-tokenizer decoder: every decoder transformer layer is "sliding_attention" with a window of 72 frames in the
  reference; upstream attended to all frames. Output now equals the official PyTorch decoder (SNR 110 to 116 dB,
  max difference 1.4e-6); without the window a 111-frame utterance deviated (SNR 32 dB).
- Text tokenizer: built in memory like Qwen2/Qwen3's tokenizer.json, with the NFC normalizer and Qwen2's split
  regex with single digits (`\p{N}`; upstream used `\p{N}{1,3}` and no normalizer). Token ids equal transformers'
  `Qwen2Tokenizer` for 12 test lines (chat templates, digits, NFD umlauts, CJK, whitespace).
- Speaker-encoder mel: periodic Hann window, like `torch.hann_window` in the reference `mel_spectrogram`.
- Sampling as in the reference (`generation_config.json`): logits in float32; repetition penalty, special-token
  suppression, then temperature, top-k, top-p; EOS blocked for the first two frames (`min_new_tokens=2`); no EOS
  re-insertion after top-k (upstream did that); the code predictor uses the `subtalker_*` settings; `do_sample=false`
  means greedy.
- Decoding: upstream trimmed the audio to the number of frames whose first code is > 0, but code 0 is valid (the
  reference counts all frames); nothing is trimmed now. The waveform comes from the stateful streaming decoder in
  steps of 12 frames, which equals one decode of the whole sequence and thus the reference's `chunked_decode` up to
  300 frames (SNR 110.8 dB). Decoding in one pass, as upstream and the reference do up to 300 frames, needed on the
  M1 8 GB 2.8 GB on top of the model for 111 frames and 3.35 GB for 150 frames (about 5 GB estimated for 300);
  12-frame steps need about 1.2 GB regardless of the length (MLX peak 3.26 GB with the 1.7B VoiceDesign model
  instead of 4.9 GB for the 111-frame test sentence). Beyond 300 frames the reference re-decodes with 25 frames of
  left context; here the decode stays continuous.
- Frame cap against a missing EOS: 8 frames per text token (at least 75, at most `max_new_tokens`) instead of 6;
  measured speech used 2.8 to 4.5.
- The last reference recording is cached by its samples (upstream: by object identity of the array).
- Missing files or weights throw `Qwen3TTSError` instead of printing a warning or calling `fatalError`.

New: `Sources/Qwen3TTSKit/Qwen3TTS.swift` (public API `Qwen3TTS`: `load(directory:)`, `design`, `clone`,
`kind`, `sampleRate`, `languages`, `speakers`, `sampling`, `lastRun`, `textTokenIDs`) and the command-line check
`Sources/qwen3tts-check`.

Build with xcodebuild (MLX needs its Metal library), e.g.
`xcodebuild -scheme qwen3tts-check -destination 'platform=macOS,arch=arm64' -configuration Release
-skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO build`.

---

Übernommen aus mlx-audio-swift (MIT, Commit 0dda61b): das Qwen3-TTS-Modell und die Mimi-Teile des
Sprach-Tokenizer-Encoders, angepasst an mlx-swift 0.31.6 (MLXArray statt MaterializedArray, MLXLMCommon 3.31.4
statt der eigenen Kopien). Gegen die offizielle Referenz (QwenLM/Qwen3-TTS, transformers) geprüft und korrigiert:
RoPE des Encoders (vorher bekam das Klonen mit Transkript größtenteils falsche Referenz-Codes), Fenster von 72
Frames im Decoder, Tokenizer mit Einzelziffern und NFC, periodisches Hann-Fenster, Sampling wie in der Referenz.
Dekodiert wird schrittweise in 12-Frame-Stücken (gleiches Ergebnis, etwa 1,2 GB zusätzlich statt 2,8 GB für einen
9-Sekunden-Satz in einem Durchgang),
dazu eine eigene synchrone API mit Seed und Abbruch-Closure und ein Kommandozeilen-Test.
