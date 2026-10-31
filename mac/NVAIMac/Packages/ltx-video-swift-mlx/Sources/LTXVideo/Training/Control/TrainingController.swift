// TrainingController.swift - Pause/Resume/Stop control for LoRA training
// Copyright 2026

import Foundation

/// Training session status
public enum TrainingStatus: String, Codable, Sendable {
    case idle, running, paused, checkpointing, completed, failed, cancelled
}

/// Observer protocol for training events.
/// All methods have default empty implementations.
public protocol TrainingObserver: AnyObject {
    func trainingStatusChanged(_ status: TrainingStatus)
    func trainingStepCompleted(step: Int, totalSteps: Int, loss: Float)
    func trainingCheckpointSaved(step: Int, path: String)
    func trainingPaused(atStep: Int)
    func trainingResumed(atStep: Int)
    func trainingFinished(success: Bool, message: String)
}

public extension TrainingObserver {
    func trainingStatusChanged(_ status: TrainingStatus) {}
    func trainingStepCompleted(step: Int, totalSteps: Int, loss: Float) {}
    func trainingCheckpointSaved(step: Int, path: String) {}
    func trainingPaused(atStep: Int) {}
    func trainingResumed(atStep: Int) {}
    func trainingFinished(success: Bool, message: String) {}
}

/// Controls training execution with pause/resume/stop support.
///
/// Uses dual signaling: in-process flags AND file-based sentinel files
/// (`.pause`, `.stop`, `.checkpoint`) in the output directory. This allows
/// cross-process control — a CLI command can pause a running training session
/// by creating a `.pause` file.
///
/// ## Usage (in-process)
/// ```swift
/// let controller = TrainingController(outputDir: "/tmp/lora-output")
/// // ... pass to trainer ...
/// controller.requestPause()   // pause at next step
/// controller.resume()         // resume training
/// controller.requestStop()    // graceful stop (saves checkpoint)
/// ```
///
/// ## Usage (cross-process, from CLI)
/// ```swift
/// TrainingController.pauseTraining(outputDir: "/tmp/lora-output")
/// TrainingController.resumeTraining(outputDir: "/tmp/lora-output")
/// TrainingController.stopTraining(outputDir: "/tmp/lora-output")
/// ```
public final class TrainingController: @unchecked Sendable {

    private let outputDir: String
    private let lock = NSLock()

    // In-process flags
    private var _pauseRequested = false
    private var _stopRequested = false
    private var _forceStopRequested = false
    private var _checkpointRequested = false
    private var _status: TrainingStatus = .idle

    // Observers (weak refs)
    private var observers: [WeakObserver] = []

    private class WeakObserver {
        weak var value: (any TrainingObserver)?
        init(_ value: any TrainingObserver) { self.value = value }
    }

    // File sentinel names
    private static let pauseFile = ".pause"
    private static let stopFile = ".stop"
    private static let checkpointFile = ".checkpoint"

    public var status: TrainingStatus {
        lock.lock()
        defer { lock.unlock() }
        return _status
    }

    public init(outputDir: String) {
        self.outputDir = outputDir
    }

    // MARK: - Observer Management

    public func addObserver(_ observer: any TrainingObserver) {
        lock.lock()
        observers.removeAll { $0.value == nil }
        observers.append(WeakObserver(observer))
        lock.unlock()
    }

    /// Notify all observers with a closure. Safe to call from any thread.
    public func notifyObservers(_ block: (any TrainingObserver) -> Void) {
        lock.lock()
        let active = observers.compactMap { $0.value }
        lock.unlock()
        for obs in active { block(obs) }
    }

    // MARK: - Control Commands (in-process)

    /// Request pause at the next training step. Returns immediately.
    public func requestPause() {
        lock.lock()
        _pauseRequested = true
        lock.unlock()
        createSentinel(Self.pauseFile)
    }

    /// Resume training after a pause.
    public func resume() {
        lock.lock()
        _pauseRequested = false
        lock.unlock()
        deleteSentinel(Self.pauseFile)
    }

    /// Request graceful stop — saves a checkpoint before stopping.
    public func requestStop() {
        lock.lock()
        _stopRequested = true
        lock.unlock()
        createSentinel(Self.stopFile)
    }

    /// Force stop — no checkpoint saved.
    public func forceStop() {
        lock.lock()
        _forceStopRequested = true
        _stopRequested = true
        lock.unlock()
    }

    /// Request an on-demand checkpoint at the next step.
    public func requestCheckpoint() {
        lock.lock()
        _checkpointRequested = true
        lock.unlock()
        createSentinel(Self.checkpointFile)
    }

    // MARK: - Polling (called by training loop)

    /// Check if pause was requested (in-process flag OR file sentinel).
    public func shouldPause() -> Bool {
        lock.lock()
        let flag = _pauseRequested
        lock.unlock()
        return flag || sentinelExists(Self.pauseFile)
    }

    /// Check if stop was requested (in-process flag OR file sentinel).
    public func shouldStop() -> Bool {
        lock.lock()
        let flag = _stopRequested
        lock.unlock()
        return flag || sentinelExists(Self.stopFile)
    }

    /// Check if force stop was requested.
    public func shouldForceStop() -> Bool {
        lock.lock()
        let flag = _forceStopRequested
        lock.unlock()
        return flag
    }

    /// Check if a checkpoint was requested. Auto-clears after reading.
    public func shouldCheckpoint() -> Bool {
        lock.lock()
        let flag = _checkpointRequested
        _checkpointRequested = false
        lock.unlock()

        let fileExists = sentinelExists(Self.checkpointFile)
        if fileExists { deleteSentinel(Self.checkpointFile) }

        return flag || fileExists
    }

    /// Block until unpaused or stopped. Returns `false` if stop was requested.
    public func waitWhilePaused() -> Bool {
        setStatus(.paused)
        while shouldPause() && !shouldStop() {
            Thread.sleep(forTimeInterval: 0.5)
        }
        if shouldStop() { return false }
        setStatus(.running)
        return true
    }

    // MARK: - Status

    public func setStatus(_ status: TrainingStatus) {
        lock.lock()
        _status = status
        lock.unlock()
        notifyObservers { $0.trainingStatusChanged(status) }
    }

    public func notifyStepCompleted(step: Int, totalSteps: Int, loss: Float) {
        notifyObservers { $0.trainingStepCompleted(step: step, totalSteps: totalSteps, loss: loss) }
    }

    // MARK: - Static CLI Helpers (file-based, no controller instance needed)

    /// Create a `.pause` sentinel file to pause a running training session.
    public static func pauseTraining(outputDir: String) {
        let path = (outputDir as NSString).appendingPathComponent(pauseFile)
        FileManager.default.createFile(atPath: path, contents: nil)
    }

    /// Delete the `.pause` sentinel to resume training.
    public static func resumeTraining(outputDir: String) {
        let path = (outputDir as NSString).appendingPathComponent(pauseFile)
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Create a `.stop` sentinel to stop a running training session.
    public static func stopTraining(outputDir: String) {
        let path = (outputDir as NSString).appendingPathComponent(stopFile)
        FileManager.default.createFile(atPath: path, contents: nil)
    }

    /// Check if training is currently paused.
    public static func isPaused(outputDir: String) -> Bool {
        let path = (outputDir as NSString).appendingPathComponent(pauseFile)
        return FileManager.default.fileExists(atPath: path)
    }

    /// Clean up leftover control files from a previous run.
    public static func cleanupControlFiles(outputDir: String) {
        let fm = FileManager.default
        for file in [pauseFile, stopFile, checkpointFile] {
            let path = (outputDir as NSString).appendingPathComponent(file)
            try? fm.removeItem(atPath: path)
        }
    }

    // MARK: - Private Helpers

    private func sentinelPath(_ name: String) -> String {
        (outputDir as NSString).appendingPathComponent(name)
    }

    private func sentinelExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: sentinelPath(name))
    }

    private func createSentinel(_ name: String) {
        FileManager.default.createFile(atPath: sentinelPath(name), contents: nil)
    }

    private func deleteSentinel(_ name: String) {
        try? FileManager.default.removeItem(atPath: sentinelPath(name))
    }
}
