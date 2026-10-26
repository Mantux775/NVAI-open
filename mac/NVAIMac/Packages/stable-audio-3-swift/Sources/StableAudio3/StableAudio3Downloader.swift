import Foundation

/// Downloads one published SA3 bundle from `aufklarer/Stable-Audio-3-…` and
/// returns the per-component sub-directories the runtime expects:
///   bundle/
///     dit_{medium,sm_music,sm_sfx}/model.safetensors + manifest.json
///     same_{l,s}_{encoder,decoder}/model.safetensors + manifest.json
///     t5gemma/model.safetensors + manifest.json
///     README.md, manifest.json
public enum StableAudio3Downloader {

    public struct BundlePaths: Sendable {
        public let root: URL
        public let dit: URL
        public let sameEncoder: URL
        public let sameDecoder: URL
        public let t5gemma: URL
    }

    /// Ensure the variant's bundle is fully present in the HF cache, returning
    /// the resolved per-component directories.
    ///
    /// If `localBundleOverride` is provided, the downloader skips HuggingFace
    /// entirely and uses that directory as the bundle root — used by the
    /// smoke-test harness to point at a pre-built local bundle without paying
    /// the ~5 GB download cost.
    public static func ensureDownloaded(
        variant: StableAudio3Variant,
        localBundleOverride: URL? = nil,
        downloadOptions: DownloadOptions = .init(),
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> BundlePaths {
        let repo = variant.huggingFaceRepoId
        // NVAI-open: the app downloads the bundle itself into its model folder and always passes it here.
        guard let root = localBundleOverride else {
            throw StableAudio3Error.missingBundle("No bundle directory given for \(repo)")
        }

        let ditDir = SA3Components.dit(for: variant)
        let encDir = SA3Components.sameEncoder(for: variant)
        let decDir = SA3Components.sameDecoder(for: variant)

        // Skip download when every component's model.safetensors is already
        // present locally — handles both pre-warmed caches and the
        // `localBundleOverride` smoke-test path.
        // NVAI-open: generating needs no SAME encoder (only audio-to-audio would), so it is not required.
        let allPresent = [ditDir, decDir, SA3Components.t5gemma].allSatisfy { sub in
            let f = root.appendingPathComponent(sub, isDirectory: true)
                        .appendingPathComponent("model.safetensors")
            return FileManager.default.fileExists(atPath: f.path)
        }

        guard allPresent else {
            throw StableAudio3Error.missingBundle("Stable Audio 3 files missing in \(root.path)")
        }
        _ = downloadOptions
        progressHandler?(1.0)

        return BundlePaths(
            root: root,
            dit: root.appendingPathComponent(ditDir, isDirectory: true),
            sameEncoder: root.appendingPathComponent(encDir, isDirectory: true),
            sameDecoder: root.appendingPathComponent(decDir, isDirectory: true),
            t5gemma: root.appendingPathComponent(SA3Components.t5gemma, isDirectory: true)
        )
    }
}
