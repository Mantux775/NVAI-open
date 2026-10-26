// NVAI-open: tiled AE decode for Macs with little memory (see NVAI-OPEN-CHANGES.md).
//
// The fp32 decode of the FLUX.1 AE needs about 12.3 GB at 1024² (README, "Decode memory"), more than an
// 8 GB Mac has. Decoding overlapping latent tiles and blending them linearly over the overlap is not exact:
// each tile's GroupNorms see the tile instead of the whole frame. The overlap hides the difference.

import MLX

extension AutoencoderKL {
    /// Decode `z` (model space after `z / scalingFactor + shiftFactor`, [1, 16, h, w]) in tiles of at most
    /// `maxTile` latent pixels a side with at least `overlap` latents between neighbours. Returns [-1, 1] NCHW
    /// like `decode`; a latent that fits one tile goes through `decode` unchanged.
    public func decodeTiled(_ z: MLXArray, maxTile: Int, overlap: Int,
                            onTile: ((Int, Int) -> Void)? = nil) -> MLXArray {
        let h = z.dim(2), w = z.dim(3)
        if h <= maxTile && w <= maxTile { return decode(z) }

        // n tiles per axis, equal size, starts spread evenly over the axis.
        func layout(_ n: Int) -> (size: Int, starts: [Int]) {
            if n <= maxTile { return (n, [0]) }
            let count = Int((Double(n - overlap) / Double(maxTile - overlap)).rounded(.up))
            let size = Int((Double(n + (count - 1) * overlap) / Double(count)).rounded(.up))
            let starts = (0 ..< count).map { i in
                Int((Double(i) * Double(n - size) / Double(count - 1)).rounded())
            }
            return (size, starts)
        }
        let (th, ys) = layout(h)
        let (tw, xs) = layout(w)
        let scale = 8
        let H = h * scale, W = w * scale
        let ph = th * scale, pw = tw * scale

        /// Linear weight over the part shared with the previous or next tile; 1 elsewhere.
        func ramp(_ start: Int, _ size: Int, _ starts: [Int], _ index: Int) -> [Float] {
            var r = [Float](repeating: 1, count: size * scale)
            if index > 0 {
                let shared = (starts[index - 1] + size - start) * scale
                for i in 0 ..< shared { r[i] = min(r[i], (Float(i) + 0.5) / Float(shared)) }
            }
            if index < starts.count - 1 {
                let shared = (start + size - starts[index + 1]) * scale
                for i in 0 ..< shared { r[size * scale - 1 - i] = min(r[size * scale - 1 - i], (Float(i) + 0.5) / Float(shared)) }
            }
            return r
        }

        var sum = [Float](repeating: 0, count: 3 * H * W)
        var weight = [Float](repeating: 0, count: H * W)
        let total = ys.count * xs.count
        var done = 0
        for (iy, y0) in ys.enumerated() {
            let wy = ramp(y0, th, ys, iy)
            for (ix, x0) in xs.enumerated() {
                let wx = ramp(x0, tw, xs, ix)
                // NHWC straight from the decoder (contiguous), [1, ph, pw, 3].
                let part = decoder(z[0..., 0..., y0 ..< y0 + th, x0 ..< x0 + tw].transposed(0, 2, 3, 1))
                    .asType(.float32)
                eval(part)
                let px = part.asArray(Float.self)
                Memory.clearCache()
                for yy in 0 ..< ph {
                    let gy = y0 * scale + yy
                    for xx in 0 ..< pw {
                        let a = wy[yy] * wx[xx]
                        let g = gy * W + x0 * scale + xx
                        let i = (yy * pw + xx) * 3
                        weight[g] += a
                        for c in 0 ..< 3 { sum[c * H * W + g] += a * px[i + c] }
                    }
                }
                done += 1
                onTile?(done, total)
            }
        }
        for c in 0 ..< 3 {
            for g in 0 ..< H * W { sum[c * H * W + g] /= max(weight[g], 1e-6) }
        }
        return MLXArray(sum, [1, 3, H, W])
    }
}
