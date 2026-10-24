// Flux2ModelChainTests.swift — Cover the model-level flags consumed by chains
// Copyright 2025 Vincent Gourbin
//
// These flags are off the critical path of every other test, so they live in
// their own file. A regression here would silently break classical-CFG gating
// or the chain defaults — both are user-visible only after a 10-min run.

import XCTest
@testable import Flux2Core

final class Flux2ModelChainTests: XCTestCase {

    // MARK: - usesClassicalCFG

    func testClassicalCFGEnabledOnlyForKleinBaseModels() {
        XCTAssertTrue(Flux2Model.klein4BBase.usesClassicalCFG)
        XCTAssertTrue(Flux2Model.klein9BBase.usesClassicalCFG)

        XCTAssertFalse(Flux2Model.dev.usesClassicalCFG)
        XCTAssertFalse(Flux2Model.klein4B.usesClassicalCFG)
        XCTAssertFalse(Flux2Model.klein9B.usesClassicalCFG)
        XCTAssertFalse(Flux2Model.klein9BKV.usesClassicalCFG)
    }

    func testDevUsesEmbeddedGuidanceNotClassicalCFG() {
        // dev is non-distilled but its guidance is baked into a transformer
        // embedding (model.usesGuidanceEmbeds == true), so it must NOT trip
        // the classical-CFG path.
        XCTAssertTrue(Flux2Model.dev.usesGuidanceEmbeds)
        XCTAssertFalse(Flux2Model.dev.usesClassicalCFG)
    }

    // MARK: - defaultGuidance

    func testDefaultGuidancePerVariant() {
        XCTAssertEqual(Flux2Model.dev.defaultGuidance, 4.0)
        XCTAssertEqual(Flux2Model.klein4B.defaultGuidance, 1.0,
                       "Distilled klein expects no CFG, guidance = 1")
        XCTAssertEqual(Flux2Model.klein9B.defaultGuidance, 1.0)
        XCTAssertEqual(Flux2Model.klein9BKV.defaultGuidance, 1.0)
        XCTAssertEqual(Flux2Model.klein4BBase.defaultGuidance, 3.5,
                       "Base klein expects classical CFG — diffusers default is around 3.5–4")
        XCTAssertEqual(Flux2Model.klein9BBase.defaultGuidance, 3.5)
    }

    // MARK: - defaultSteps

    func testDefaultStepsPerVariant() {
        XCTAssertEqual(Flux2Model.dev.defaultSteps, 28)
        XCTAssertEqual(Flux2Model.klein4B.defaultSteps, 4)
        XCTAssertEqual(Flux2Model.klein9B.defaultSteps, 4)
        XCTAssertEqual(Flux2Model.klein9BKV.defaultSteps, 4)
        XCTAssertEqual(Flux2Model.klein4BBase.defaultSteps, 28,
                       "Base models need more steps — no distillation shortcut")
        XCTAssertEqual(Flux2Model.klein9BBase.defaultSteps, 28)
    }

    // MARK: - usesGuidanceEmbeds (sanity, ensures we didn't regress the existing logic)

    func testUsesGuidanceEmbedsOnlyDev() {
        XCTAssertTrue(Flux2Model.dev.usesGuidanceEmbeds)
        for m: Flux2Model in [.klein4B, .klein4BBase, .klein9B, .klein9BBase, .klein9BKV] {
            XCTAssertFalse(m.usesGuidanceEmbeds, "\(m) should not use embedded guidance")
        }
    }

    // MARK: - CFG gating logic

    func testCFGGateForEachVariant() {
        // The pipeline triggers classical-CFG when `usesClassicalCFG && guidance > 1`.
        // Enumerate the matrix so future variant additions force a deliberate
        // choice rather than inheriting a quiet default.
        for m: Flux2Model in [.dev, .klein4B, .klein4BBase, .klein9B, .klein9BBase, .klein9BKV] {
            let g1: Float = 1.0
            let g4: Float = 4.0
            let gateLow = m.usesClassicalCFG && g1 > 1.0
            let gateHigh = m.usesClassicalCFG && g4 > 1.0
            // No model should ever be CFG-gated at guidance == 1 (the gate
            // is strict-greater-than, so the cheap path stays cheap).
            XCTAssertFalse(gateLow, "\(m) at guidance=1 should never trip classical CFG")
            // Klein-base at guidance > 1 must trip CFG.
            if m == .klein4BBase || m == .klein9BBase {
                XCTAssertTrue(gateHigh, "\(m) at guidance=4 must trip classical CFG")
            } else {
                XCTAssertFalse(gateHigh, "\(m) at guidance=4 must NOT trip classical CFG")
            }
        }
    }
}
