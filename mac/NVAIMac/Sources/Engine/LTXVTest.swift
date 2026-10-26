import Foundation
import MLX
import LTXV
import Tokenizers

/// Prüfstand für den LTX-Video-Port (`--ltxv-test <ordner>`): liest `inputs.safetensors` (Token-IDs, Transformer- und
/// Decoder-Eingaben, von `scratchpad/ltxv/reference.py` aus ComfyUI erzeugt) und `prompt.txt`, rechnet T5,
/// Transformer und Decoder (ungekachelt und gekachelt) und schreibt `swift_out.safetensors` zum Vergleich.
enum LTXVTest {
    static func run(_ dir: String) async {
        let base = URL(fileURLWithPath: dir)
        let models = Settings.modelsDirectory
        let ltx = models.appendingPathComponent("Lightricks/LTX-Video/ltxv-2b-0.9.8-distilled")
        let t5Dir = models.appendingPathComponent("dhairyashil/FLUX.1-schnell-mflux-4bit")
        do {
            let inputs = try MLX.loadArrays(url: base.appendingPathComponent("inputs.safetensors"))
            var out: [String: MLXArray] = [:]

            // T5: Tokenizer und Encoder
            let tokenizer = try await AutoTokenizer.from(modelFolder: t5Dir.appendingPathComponent("nvai/tokenizer"))
            var t5: T5Encoder? = try LTXWeights.loadT5(
                directory: t5Dir.appendingPathComponent("text_encoder_2"),
                relativeBias: t5Dir.appendingPathComponent("nvai/t5-relative-bias.safetensors"))
            MemoryLog.line("LTXV test: T5 loaded")
            let prompt = (try? String(contentsOf: base.appendingPathComponent("prompt.txt"), encoding: .utf8)) ?? ""
            out["swift_ids"] = MLXArray(T5TextEncoder(encoder: t5!, tokenizer: tokenizer).tokens(prompt).map(Int32.init))
            if let ids = inputs["prompt_ids"] {
                let t0 = Date()
                out["t5_out"] = t5!(ids.asType(.int32))
                eval(out["t5_out"]!)
                AppLog.info(String(format: "LTXV test: T5 %.2f s for %d tokens", Date().timeIntervalSince(t0), ids.dim(1)))
            }
            t5 = nil
            Memory.clearCache()

            // Transformer: die ersten zwei Blöcke in float32 (Fehlersuche), dann alle in bf16
            if let tokens = inputs["dit_tokens"], let context = inputs["dit_context"], let sigma = inputs["dit_sigma"],
               let shape = inputs["dit_shape"] {
                for n in [1, 2, 14] {
                    let part = try LTXWeights.loadTransformer(file: ltx.appendingPathComponent("dit.safetensors"),
                                                              dtype: .float32, layers: n)
                    let s = shape.asArray(Int32.self).map(Int.init)
                    let rope = part.rope(frames: s[0], height: s[1], width: s[2], frameRate: 24)
                    let v = part(tokens, sigma: sigma.item(Float.self), context: context, rope: rope)
                    eval(v)
                    out["dit_out_\(n)"] = v
                }
                Memory.clearCache()
                var dit: LTXTransformer? = try LTXWeights.loadTransformer(file: ltx.appendingPathComponent("dit.safetensors"))
                MemoryLog.line("LTXV test: transformer loaded")
                let s = shape.asArray(Int32.self).map(Int.init)
                let rope = dit!.rope(frames: s[0], height: s[1], width: s[2], frameRate: 24)
                let t0 = Date()
                let v = dit!(tokens, sigma: sigma.item(Float.self), context: context, rope: rope).asType(.float32)
                eval(v)
                AppLog.info(String(format: "LTXV test: transformer %.2f s for %d tokens", Date().timeIntervalSince(t0), tokens.dim(1)))
                out["dit_out"] = v

                dit = nil
                Memory.clearCache()
            }

            // Decoder: ungekachelt und in kleinen Kacheln (muss gleich sein)
            if let z = inputs["vae_z"] {
                let decoder = try LTXWeights.loadDecoder(file: ltx.appendingPathComponent("vae-decoder.safetensors"))
                MemoryLog.line("LTXV test: decoder loaded")
                var t0 = Date()
                out["vae_out"] = decoder.decode(z, noise: nil, dtype: .float32)
                AppLog.info(String(format: "LTXV test: decoder %.2f s", Date().timeIntervalSince(t0)))
                t0 = Date()
                out["vae_out_tiled"] = decoder.decode(z, noise: nil, dtype: .float32, tile: 4)
                AppLog.info(String(format: "LTXV test: decoder tiled %.2f s", Date().timeIntervalSince(t0)))
            }
            try MLX.save(arrays: out, url: base.appendingPathComponent("swift_out.safetensors"))
            AppLog.info("LTXV test written")
        } catch {
            AppLog.error("LTXV test failed: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))")
        }
    }

    /// Prüfstand fürs Startbild (`--ltxv-i2v-test <ordner>`, seit 0.4.8): `inputs_i2v.safetensors` und die rohen
    /// Encoder-Gewichte `vae-encoder.safetensors` (3D-Kerne aus der Einzeldatei) von `scratchpad/ltxv/reference_i2v.py`.
    /// Rechnet den Encoder aus den 3D-Kernen und aus der umgewandelten float16-Datei, dazu den Transformer mit Zeitschritt
    /// 0 für die Token des Startbilds, und schreibt `swift_i2v.safetensors`.
    static func runImageToVideo(_ dir: String) async {
        let base = URL(fileURLWithPath: dir)
        let ltx = Settings.modelsDirectory.appendingPathComponent("Lightricks/LTX-Video/ltxv-2b-0.9.8-distilled")
        do {
            let inputs = try MLX.loadArrays(url: base.appendingPathComponent("inputs_i2v.safetensors"))
            var out: [String: MLXArray] = [:]
            let config = (try? JSONSerialization.jsonObject(with: Data(contentsOf: ltx.appendingPathComponent("config.json"))))
                .flatMap { $0 as? [String: Any] }?["vae"] as? [String: Any]
            if let image = inputs["enc_image"] {
                let raw = base.appendingPathComponent("vae-encoder.safetensors")
                var t0 = Date()
                var encoder: LTXImageEncoder? = try LTXWeights.loadImageEncoder(file: raw, config: config)
                out["enc_latent"] = encoder!.encode(image)
                eval(out["enc_latent"]!)
                AppLog.info(String(format: "LTXV i2v test: encoder (3D kernels) %.2f s", Date().timeIntervalSince(t0)))
                encoder = nil
                Memory.clearCache()
                let converted = base.appendingPathComponent("vae-encoder-2d.safetensors")
                t0 = Date()
                try LTXWeights.convertImageEncoder(raw: raw, to: converted)
                AppLog.info(String(format: "LTXV i2v test: converted in %.2f s", Date().timeIntervalSince(t0)))
                t0 = Date()
                encoder = try LTXWeights.loadImageEncoder(file: converted, config: config)
                out["enc_latent_fp16"] = encoder!.encode(image)
                eval(out["enc_latent_fp16"]!)
                AppLog.info(String(format: "LTXV i2v test: encoder (converted) %.2f s", Date().timeIntervalSince(t0)))
                encoder = nil
                Memory.clearCache()
            }
            if let tokens = inputs["dit_tokens"], let context = inputs["dit_context"], let sigma = inputs["dit_sigma"],
               let shape = inputs["dit_shape"], let conditioned = inputs["dit_conditioned"] {
                let s = shape.asArray(Int32.self).map(Int.init)
                let k = Int(conditioned.item(Int32.self))
                let one = try LTXWeights.loadTransformer(file: ltx.appendingPathComponent("dit.safetensors"), dtype: .float32, layers: 1)
                let rope1 = one.rope(frames: s[0], height: s[1], width: s[2], frameRate: 24)
                out["dit_cond_out_1"] = one(tokens, sigma: sigma.item(Float.self), context: context, rope: rope1, conditionedTokens: k)
                eval(out["dit_cond_out_1"]!)
                Memory.clearCache()
                var dit: LTXTransformer? = try LTXWeights.loadTransformer(file: ltx.appendingPathComponent("dit.safetensors"))
                let rope = dit!.rope(frames: s[0], height: s[1], width: s[2], frameRate: 24)
                out["dit_cond_out"] = dit!(tokens, sigma: sigma.item(Float.self), context: context, rope: rope,
                                           conditionedTokens: k).asType(.float32)
                eval(out["dit_cond_out"]!)
                dit = nil
                Memory.clearCache()
            }
            try MLX.save(arrays: out, url: base.appendingPathComponent("swift_i2v.safetensors"))
            AppLog.info("LTXV i2v test written")
        } catch {
            AppLog.error("LTXV i2v test failed: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))")
        }
    }
}
