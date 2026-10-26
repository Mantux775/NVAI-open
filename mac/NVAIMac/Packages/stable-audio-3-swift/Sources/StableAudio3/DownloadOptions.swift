import Foundation

/// A failed download attempt, reported before its retry delay begins.
///
/// The last attempt has no retry delay. It does not necessarily mean the load
/// failed: the downloader may still use a complete cache after reporting it.
public struct DownloadRetryEvent: Sendable {
    public let modelId: String
    /// One-based index of the attempt that just failed.
    public let attempt: Int
    public let maxAttempts: Int
    /// The original attempt error, before retry-exhaustion wrapping.
    public let error: any Error
    /// Delay before the next attempt, or `nil` when no retries remain.
    public let retryInSeconds: Int?

    public init(
        modelId: String, attempt: Int, maxAttempts: Int,
        error: any Error, retryInSeconds: Int?
    ) {
        self.modelId = modelId
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.error = error
        self.retryInSeconds = retryInSeconds
    }
}

/// Retry settings and observation for one model load and its asset downloads.
public struct DownloadOptions: Sendable {
    /// Delays between attempts. `nil` keeps the loader's existing policy
    /// (5/15/30/60 seconds for shared manifest downloads). An empty array
    /// permits only the initial attempt.
    public var retryDelaysSeconds: [Int]?

    /// Called once per failed attempt, before sleeping, including the last one.
    /// Cancellation is propagated without a retry event. The callback runs
    /// synchronously with no main-actor guarantee and should return promptly.
    public var onRetry: (@Sendable (DownloadRetryEvent) -> Void)?

    public init(
        retryDelaysSeconds: [Int]? = nil,
        onRetry: (@Sendable (DownloadRetryEvent) -> Void)? = nil
    ) {
        self.retryDelaysSeconds = retryDelaysSeconds
        self.onRetry = onRetry
    }
}
