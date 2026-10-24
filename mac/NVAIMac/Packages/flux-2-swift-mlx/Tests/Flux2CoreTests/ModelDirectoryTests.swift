// ModelDirectoryTests.swift - Tests for custom model directory configuration
// Copyright 2025 Vincent Gourbin

import XCTest
@testable import Flux2Core

final class ModelDirectoryTests: XCTestCase {

    // MARK: - Setup / Teardown

    override func tearDown() {
        // Always reset to default after each test
        ModelRegistry.customModelsDirectory = nil
        super.tearDown()
    }

    // MARK: - ModelRegistry.customModelsDirectory

    func testDefaultModelsDirectoryIsCachesModels() {
        let expected = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("models", isDirectory: true)
        XCTAssertEqual(ModelRegistry.modelsDirectory, expected)
    }

    func testCustomModelsDirectoryOverridesDefault() {
        let custom = URL(fileURLWithPath: "/tmp/test-models")
        ModelRegistry.customModelsDirectory = custom
        XCTAssertEqual(ModelRegistry.modelsDirectory, custom)
    }

    func testCustomModelsDirectoryNilFallsBackToDefault() {
        let custom = URL(fileURLWithPath: "/tmp/test-models")
        ModelRegistry.customModelsDirectory = custom
        XCTAssertEqual(ModelRegistry.modelsDirectory, custom)

        ModelRegistry.customModelsDirectory = nil
        let expected = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("models", isDirectory: true)
        XCTAssertEqual(ModelRegistry.modelsDirectory, expected)
    }

    func testLocalPathUsesCustomDirectory() {
        let custom = URL(fileURLWithPath: "/tmp/test-models")
        ModelRegistry.customModelsDirectory = custom

        let path = ModelRegistry.localPath(for: .transformer(.klein4B_bf16))
        XCTAssertTrue(path.path.hasPrefix("/tmp/test-models/"))
    }

    func testLocalPathUsesDefaultDirectoryWhenNoCustom() {
        let path = ModelRegistry.localPath(for: .transformer(.klein4B_bf16))
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        XCTAssertTrue(path.path.hasPrefix(cacheDir.path))
    }

    // MARK: - Flux2ModelDownloader.findModelPath uses custom directory

    func testFindModelPathChecksCustomDirectory() throws {
        // Create a temp directory structure mimicking a model
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flux2-test-\(UUID().uuidString)")
            .appendingPathComponent("models")
        let repoDir = tempDir
            .appendingPathComponent("black-forest-labs")
            .appendingPathComponent("FLUX.2-klein-4B-klein4b-bf16")

        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)

        // Create a fake config.json and safetensors file
        try "{}".write(to: repoDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try Data().write(to: repoDir.appendingPathComponent("flux-2-klein-dummy.safetensors"))

        defer {
            try? FileManager.default.removeItem(at: tempDir.deletingLastPathComponent())
        }

        // Point customModelsDirectory to our temp dir
        ModelRegistry.customModelsDirectory = tempDir

        // localPath should point into our custom directory
        let localPath = ModelRegistry.localPath(for: .transformer(.klein4B_bf16))
        XCTAssertEqual(localPath.standardizedFileURL.path, repoDir.standardizedFileURL.path)

        // findModelPath should find the model at the custom location
        let found = Flux2ModelDownloader.findModelPath(for: .transformer(.klein4B_bf16))
        XCTAssertNotNil(found)
        XCTAssertTrue(found!.path.hasPrefix(tempDir.path))
    }

    func testFindModelPathReturnsNilWhenCustomDirEmpty() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flux2-test-\(UUID().uuidString)")
            .appendingPathComponent("models")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir.deletingLastPathComponent())
        }

        ModelRegistry.customModelsDirectory = tempDir

        let found = Flux2ModelDownloader.findModelPath(for: .transformer(.klein4B_bf16))
        XCTAssertNil(found)
    }

    // MARK: - ModelDownloader.findModelPath with cache directory

    func testFindModelPathChecksCustomCacheDirectory() throws {
        // Create a temp directory mimicking the HubApi download location
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flux2-test-\(UUID().uuidString)")
            .appendingPathComponent("models")

        // HubApi downloads to {base}/models/{org}/{repo}
        // For klein4B, repoId is "black-forest-labs/FLUX.2-klein-4B"
        let hubCacheDir = tempDir
            .appendingPathComponent("black-forest-labs")
            .appendingPathComponent("FLUX.2-klein-4B")

        try FileManager.default.createDirectory(at: hubCacheDir, withIntermediateDirectories: true)
        try "{}".write(to: hubCacheDir.appendingPathComponent("model_index.json"), atomically: true, encoding: .utf8)
        try Data().write(to: hubCacheDir.appendingPathComponent("flux-2-klein-dummy.safetensors"))

        defer {
            try? FileManager.default.removeItem(at: tempDir.deletingLastPathComponent())
        }

        ModelRegistry.customModelsDirectory = tempDir

        // findModelPath also checks the cache directory (modelsDirectory/{org}/{repo})
        _ = Flux2ModelDownloader.findModelPath(for: .vae(.standard))
        let vaePath = ModelRegistry.localPath(for: .vae(.standard))
        XCTAssertTrue(vaePath.path.hasPrefix(tempDir.path), "VAE path should use custom directory: \(vaePath.path)")
    }

    // MARK: - Multiple custom directory switches

    func testSwitchingCustomDirectories() {
        let dir1 = URL(fileURLWithPath: "/tmp/models-a")
        let dir2 = URL(fileURLWithPath: "/tmp/models-b")

        ModelRegistry.customModelsDirectory = dir1
        XCTAssertEqual(ModelRegistry.modelsDirectory, dir1)

        ModelRegistry.customModelsDirectory = dir2
        XCTAssertEqual(ModelRegistry.modelsDirectory, dir2)

        ModelRegistry.customModelsDirectory = nil
        let defaultDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("models", isDirectory: true)
        XCTAssertEqual(ModelRegistry.modelsDirectory, defaultDir)
    }
}
