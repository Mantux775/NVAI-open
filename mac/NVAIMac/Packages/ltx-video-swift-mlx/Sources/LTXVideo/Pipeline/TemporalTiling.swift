// TemporalTiling.swift - Splitting a long canvas into overlapping denoise tiles
// Copyright 2026

import Foundation

/// One temporal tile of a latent canvas, in global latent coordinates.
///
/// Tiles are **gapless in what they own** but **overlapping in what they see**:
/// every tile after the first starts a few frames earlier than the region it
/// contributes, so it denoises *through* the boundary it shares with its
/// predecessor. Without that lead-in the two tiles would each invent their own
/// motion up to the seam and the join would visibly tick.
///
/// - `start` / `endExclusive`: the window the tile denoises.
/// - `dropPrefix`: how much of that window is lead-in, discarded when stitching
///   because the previous tile already owns those frames.
public struct TemporalTile: Equatable, Sendable {
    public let start: Int
    public let endExclusive: Int
    public let dropPrefix: Int

    public var length: Int { endExclusive - start }
    public var ownedRange: Range<Int> { (start + dropPrefix) ..< endExclusive }
}

public enum TemporalTiling {

    /// Partition `latentFrames` into windows of at most `maxTileFrames`, each
    /// overlapping its predecessor by `leadFrames`.
    ///
    /// The overlap is a *cost*: those frames are denoised twice and thrown away
    /// once. It buys seam continuity, so it is kept small — but never zero, and
    /// never larger than the window it precedes.
    public static func tiles(
        latentFrames: Int,
        maxTileFrames: Int,
        leadFrames: Int = 2
    ) -> [TemporalTile] {
        precondition(latentFrames > 0, "latentFrames must be positive")
        precondition(maxTileFrames > 1, "a tile must hold at least two frames")
        // Clamp rather than trap: an oversized lead-in is a caller's bad guess,
        // not a programming error, and it has an obvious sane answer.
        let lead = max(1, min(leadFrames, maxTileFrames - 1))

        guard latentFrames > maxTileFrames else {
            return [TemporalTile(start: 0, endExclusive: latentFrames, dropPrefix: 0)]
        }

        var result: [TemporalTile] = []
        var owned = 0                       // first frame not yet owned by a tile
        while owned < latentFrames {
            let leadHere = result.isEmpty ? 0 : min(lead, owned)
            let start = owned - leadHere
            let end = min(start + maxTileFrames, latentFrames)
            result.append(TemporalTile(start: start, endExclusive: end, dropPrefix: leadHere))
            // A tile that cannot advance past its own lead-in would loop forever.
            precondition(end > owned, "tile budget too small to make progress")
            owned = end
        }
        return result
    }

    /// Sanity check used by both the tiler's tests and its callers: the owned
    /// ranges must tile `[0, latentFrames)` exactly — no gap, no overlap.
    public static func ownedRangesCover(_ tiles: [TemporalTile], latentFrames: Int) -> Bool {
        var next = 0
        for tile in tiles {
            guard tile.ownedRange.lowerBound == next else { return false }
            next = tile.ownedRange.upperBound
        }
        return next == latentFrames
    }
}
