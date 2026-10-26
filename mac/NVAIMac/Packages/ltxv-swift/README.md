# ltxv-swift

LTX-Video 2B (Lightricks, 0.9.x, distilled) in Swift on MLX, written for NVAI-open for Mac. Part of NVAI-open (MIT).
The model weights are not part of this package; they come from Hugging Face under the LTX-Video Open Weights License
(free below US$10M annual revenue).

- `T5Encoder.swift`: the T5 v1.1 XXL encoder (24 layers, gated GELU, bucketed relative position bias, no attention
  scaling), loaded from mflux's 4-bit build with the position table in float32.
- `Transformer.swift`: the LTX video transformer (28 blocks of 2048, adaLN-single, RMS-normed attention with 3-axis
  rotary positions, cross-attention to the projected T5 features).
- `VideoDecoder.swift`: the decoder of the causal video VAE with timestep conditioning (pixel norm, depth-to-space
  upsamplers, 4 × 4 unpatchify); its last stage runs in spatial tiles with exact context.
- `ImageEncoder.swift`: the encoder of the same VAE for one start image (image to video). For a single frame every
  causal 3D convolution equals a 2D convolution with the kernel summed over time, so it runs as 2D convolutions.
- `Pipeline.swift`: eight Euler steps on the checkpoint's timesteps (with a start image: its tokens at timestep 0,
  noised by 0.15 · σ² in every step like Lightricks' `image_cond_noise_scale`), decode noise, frames out.
- `Weights.swift`: loaders for the transformer, decoder and image encoder (taken by byte range from Lightricks' single
  file; the encoder's kernels are summed over time once and stored in float16) and T5.

The structure follows Lightricks' reference implementation (github.com/Lightricks/LTX-Video, Apache-2.0). ComfyUI was
used only as a numerical reference, run on the same inputs on CPU in float32; no code was taken from it. Measured
against it: T5 relative L2 1.6e-5, transformer 3.4e-5 after 14 blocks (with a start image 3.4e-6 after one block),
decoder 1.2e-6, image encoder 4.3e-6 (1.4e-4 from the float16 file); the tiled decoder output is bit-identical to a
single pass.
