// SPDX-License-Identifier: MIT (port). SeedVR2 model/weights: Apache-2.0 / ByteDance.
import Foundation

/// SeedVR2 transformer configuration. Defaults match the 3B checkpoint
/// (mflux `SeedVR2Transformer.__init__`); 7B applies `transformerOverrides`.
public struct SeedVR2Config: Codable, Sendable {
    public var vidInChannels: Int = 33
    public var vidOutChannels: Int = 16
    public var vidDim: Int = 2560
    public var txtInDim: Int = 5120
    public var heads: Int = 20
    public var headDim: Int = 128
    public var expandRatio: Int = 4
    public var ropeOnText: Bool = true
    public var normEps: Float = 1e-5
    public var patchSize: [Int] = [1, 2, 2]
    public var numLayers: Int = 32
    public var mmLayers: Int = 10
    public var ropeDim: Int = 128
    public var window: [Int] = [4, 3, 3]

    public static let r3B = SeedVR2Config()

    public static let r7B: SeedVR2Config = {
        var c = SeedVR2Config()
        c.vidDim = 3072; c.heads = 24; c.numLayers = 36
        c.mmLayers = 36; c.ropeDim = 64; c.ropeOnText = false
        return c
    }()

    /// Apply mflux's `transformer_overrides` dict (from exported config.json).
    public mutating func apply(overrides: [String: Int]) {
        if let v = overrides["vid_dim"] { vidDim = v }
        if let v = overrides["heads"] { heads = v }
        if let v = overrides["num_layers"] { numLayers = v }
        if let v = overrides["mm_layers"] { mmLayers = v }
        if let v = overrides["rope_dim"] { ropeDim = v }
        if let v = overrides["rope_on_text"] { ropeOnText = v != 0 }
    }
}
