// SPDX-License-Identifier: MIT (port). SeedVR2 model/weights: Apache-2.0 / ByteDance.
//
// Minimal Hugging Face Hub downloader (no swift-transformers dependency). Fetches the
// handful of files a SeedVR2 repo needs into a local cache dir, skipping files already
// present. Enough for `SeedVR2Weights.from(repoId:)` / on-device first-run download.
import Foundation

public enum HFHub {
    public enum HubError: Error { case download(String) }

    /// Files a SeedVR2 weights repo contains.
    public static let seedvr2Files = [
        "config.json", "pos_emb.safetensors", "vae.safetensors", "transformer.safetensors",
    ]

    /// Download `files` from `repoId` (revision `main` by default) into a cache dir,
    /// returning the local directory. Skips files already cached with non-zero size.
    public static func snapshot(repoId: String, files: [String] = seedvr2Files,
                                revision: String = "main", cacheDir: URL? = nil) throws -> URL {
        let base = cacheDir ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("seedvr2-mlx/\(repoId.replacingOccurrences(of: "/", with: "--"))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        for file in files {
            let dst = base.appendingPathComponent(file)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: dst.path),
               (attrs[.size] as? Int ?? 0) > 0 { continue }
            let url = URL(string: "https://huggingface.co/\(repoId)/resolve/\(revision)/\(file)")!
            try downloadSync(url, to: dst)
        }
        return base
    }

    /// Synchronous download (sequential, large-file friendly). Streams to a temp file then moves.
    private static func downloadSync(_ url: URL, to dst: URL) throws {
        let sem = DispatchSemaphore(value: 0)
        var resultErr: Error?
        var tmpURL: URL?
        let task = URLSession.shared.downloadTask(with: url) { loc, resp, err in
            defer { sem.signal() }
            if let err { resultErr = err; return }
            guard let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode), let loc else {
                resultErr = HubError.download("HTTP \( (resp as? HTTPURLResponse)?.statusCode ?? -1) for \(url.lastPathComponent)")
                return
            }
            // Move out of the URLSession temp location before the callback returns.
            let staged = dst.appendingPathExtension("part")
            try? FileManager.default.removeItem(at: staged)
            do { try FileManager.default.moveItem(at: loc, to: staged); tmpURL = staged }
            catch { resultErr = error }
        }
        task.resume()
        sem.wait()
        if let resultErr { throw resultErr }
        guard let staged = tmpURL else { throw HubError.download("no file for \(url.lastPathComponent)") }
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: staged, to: dst)
    }
}
