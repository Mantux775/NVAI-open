import Foundation
import CoreGraphics
import FluxTextEncoders

/// „Automatisch“ beim Restaurieren (seit 0.4.7): Qwen3.5 4B sieht das Foto (bis 1 MP) und entscheidet wie unter
/// Windows der Upsampler von FLUX 3 nach der Art der Schäden: flächig → gründlich, einzelne Schäden → schonend.
///
/// Gemessen an den 21 Testfotos (25.10.2026, Mac mini M1): Die Windows-Frage (`jobs.RESTORE_KIND_QUESTION`)
/// beantwortete das 4B-Modell 20-mal mit „yes“ (10 von 21 richtig). Entschieden wird deshalb nicht nach der
/// Antwort, sondern nach den Log-Odds „yes“ gegen „no“ des ersten Antworttokens mit einer Schwelle, und mit der
/// Frage, die am deutlichsten trennte: stark gealterte Fotos +1,9 bis +3,0, alle anderen höchstens +0,8; 20 von
/// 21 wie erwartet (die Ferrotypie bekam +0,5 und wird schonend; unter Windows lagen dafür die Tauben daneben).
/// Mit der Windows-Frage lag die beste Schwelle bei +1,44 mit nur 0,04 Abstand. Rund 20 s je Foto.
actor VisionEngine {
    static let shared = VisionEngine()

    static let system = "You are an expert in restoring old photographs. Answer with one word: yes or no."
    static let question = "Is this photograph heavily damaged, with damage spread over the whole picture? Answer yes or no."
    /// Mitte zwischen +0,8 (höchster Wert der leicht beschädigten und echten Fotos) und +1,9 (niedrigster der stark
    /// gealterten).
    static let threshold = 1.35

    /// Log-Odds je Foto (Asset-ID), wie unter Windows zwischengespeichert: dasselbe Foto bekommt dieselbe Wahl.
    private var odds: [String: Double] = [:]

    func cachedAnswer(_ assetID: String) -> Double? { odds[assetID] }

    /// Fragt das Modell; lädt es dafür und entlädt es danach wieder (`unloadAfter`), damit FLUX.2 Klein Platz hat.
    /// `answer` nennt die Log-Odds („yes“ gegen „no“), wie sie in `meta.repair.auto_answer` stehen.
    func restoreKind(_ photo: CGImage, assetID: String, unloadAfter: Bool = true) async throws -> (gentle: Bool, answer: String) {
        let value: Double
        if let cached = odds[assetID] {
            value = cached
        } else {
            defer { if unloadAfter { FluxTextEncoders.shared.unloadQwen35VLM() } }
            value = try await logOdds(photo, questions: [(Self.system, Self.question)])[0]
            odds[assetID] = value
        }
        return (value <= Self.threshold, String(format: "log-odds %+.2f (threshold %+.2f)", value, Self.threshold))
    }

    func unload() { FluxTextEncoders.shared.unloadQwen35VLM() }

    /// Prüfstand (`--restore-kind`): Fragen, deren Log-Odds („yes“ gegen „no“) gemessen werden.
    static let probeQuestions: [(system: String?, prompt: String)] = [
        (system, "Are there water stains, rings left by water, or crack networks (craquelure) in this photograph? "
            + "Answer yes or no."),
        (system, "Is this photograph in good condition apart from a few dust spots or fine scratches? Answer yes or no."),
        (system, question),
        (system, "Does this photograph show water stains, water rings or a network of fine cracks across the picture? "
            + "Answer yes or no."),
    ]

    /// Log-Odds „yes“ gegen „no“ des ersten Antworttokens je Frage, ohne zu generieren; das Modell bleibt geladen.
    func logOdds(_ photo: CGImage, questions: [(system: String?, prompt: String)]) async throws -> [Double] {
        guard let path = HelperModel.vision.localPath else {
            throw APIError(409, t("Qwen3.5 4B ist nicht geladen.", "Qwen3.5 4B is not downloaded."))
        }
        let encoders = FluxTextEncoders.shared
        if !encoders.isQwen35VLMLoaded { try await encoders.loadQwen35VLM(from: path.path) }
        guard let vlm = encoders.qwen35VLMForEvaluation else {
            throw APIError(500, t("Qwen3.5 4B ließ sich nicht laden.", "Could not load Qwen3.5 4B."))
        }
        let scores = try await Task.detached(priority: .userInitiated) {
            vlm.firstTokenLogProbs(images: [photo], questions: questions, candidates: ["yes", "Yes", "no", "No"])
        }.value
        return scores.map(Self.logOdds)
    }

    static func logOdds(_ lp: [String: Float]) -> Double {
        func lse(_ a: Float?, _ b: Float?) -> Double {
            let x = Double(a ?? -100), y = Double(b ?? -100), m = max(x, y)
            return m + log(exp(x - m) + exp(y - m))
        }
        return lse(lp["yes"], lp["Yes"]) - lse(lp["no"], lp["No"])
    }
}
