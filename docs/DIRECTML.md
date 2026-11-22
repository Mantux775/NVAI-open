# Older Radeons: DirectML and Vulkan (experimental)

[Deutsch](de/DIRECTML.md)

AMD's PyTorch for Windows (ROCm) does not support the Radeon RX 5000 series, Vega, Radeon VII or Polaris (RX 400/500).
NVAI-open computes on these cards in two ways: images and sound through **DirectML**, the machine learning layer of
DirectX 12 (since 0.5.33), and video through a second engine, **stable-diffusion.cpp with Vulkan** (since 0.5.34). Both
are experimental: NVAI-open has not run on such a card yet. Everything below was measured on an NVIDIA card whose memory
was limited to what an 8 GB card gets. Reports in [issue #3](https://github.com/Mantux775/NVAI-open/issues/3) help a lot.

## Setup

Install NVAI-open as usual, also over an older version. The setup recognises the card, adds a second ComfyUI environment
with PyTorch 2.4.1 and Microsoft's torch-directml (a download of about 200 MB), downloads stable-diffusion.cpp for
Vulkan (28 MB), and checks both on the card. The top bar then says "DirectML (experimental)"; hovering over it explains
what that means.

![The top bar with "DirectML (experimental)" and its explanation](images/directml-bar.jpg)

If DirectML does not compute on the card, or ComfyUI does not start with it, NVAI-open computes images and sound on the
processor as before. The top bar then says "Running on the CPU", and the tooltip gives the reason. If Vulkan does not
see the card, there is no video. "Repair NVAI-open" in the Start menu sets everything up again.

## Which models

Under "Models", the models that fit the card are marked as recommended, and every other model says why it does not.

- **Recommended:** the SDXL models (Juggernaut XL v9, SDXL base, Pony V6 XL, Illustrious XL, NoobAI XL) for images,
  Stable Audio Open for sound effects, and Wan 2.1 T2V 1.3B for video through Vulkan, marked as slow (3 seconds at
  832 × 480 took 4.5 to 5.5 minutes on the comparison card). New video scenes in the Studio take it by themselves, and
  under every model choice in "Generate" and in the Studio a note says what the model does on this card.
- **Slow:** Stable Audio 3 Medium for music, which needs up to 10 GB for a moment while decoding.
- **Not yet:** other video models, and the large models such as Qwen-Image, FLUX 3, Krea 2, MOSS-Image or LTX-2.5: too
  large for 8 GB, or they need NVIDIA or ROCm kernels (NVFP4, INT8, FP8). The narrator voice and 3D need CUDA or ROCm.
  The audio tools and audio forensics compute on the processor.

![Models page: Juggernaut XL recommended, Qwen-Image not for this card, Stable Audio 3 marked as slow](images/directml-models.jpg)

## Video through Vulkan

Microsoft's DirectML plugin for PyTorch only handles tensors with up to five dimensions, and video models need more in a
few places: Wan 2.1 rebuilds its frames in eight, and through DirectML it stopped after two steps of 27 s each.
stable-diffusion.cpp computes without PyTorch, directly through Vulkan, which Radeons, Intel cards and NVIDIA cards all
speak. It uses the same model files as ComfyUI (Wan 2.1 T2V 1.3B with its text encoder and VAE) and keeps the text
encoder and the VAE in system RAM, the video model on the card. Before a video, NVAI-open closes the DirectML ComfyUI so
that its memory is free; the next image or sound starts it again (about 30 s).

![Somi drives a lawnmower through a field of frightened faces, black ink with blue ears](images/vulkan-somi.gif)

<sub>Somi, the rabbit from our short film, mows a field of frightened faces: Wan 2.1 1.3B through Vulkan, 3 s at
832 × 480 in 5.5 minutes on the comparison card. Without a LoRA Wan draws him from the description alone, here black
instead of white.</sub>

## Measured: CUDA, DirectML and Vulkan on the same card

The same jobs with the same seeds on an RTX 5060 Ti 16 GB: with CUDA, through DirectML and through Vulkan, the last two
limited to the memory Windows gives an 8 GB card (7.7 GB). Times per job, including loading the model.

| Job | CUDA | DirectML | Vulkan |
|---|---|---|---|
| SDXL (Juggernaut XL v9), 1024 × 1024, 28 steps | 16 s | 83 s | 34 s¹ |
| SDXL, 832 × 1216, 28 steps | 13 s | 81 s | – |
| Stable Audio Open, 6 s sound effect | 8 s | 17 s | – |
| Stable Audio 3 Medium, 30 s of music | 6 s | 16 s | – |
| Wan 2.1 T2V 1.3B, 832 × 480, 33 frames (2 s), 30 steps | 117 s | stops after 2 steps | 194 s |

<sub>¹ Measured with stable-diffusion.cpp directly; NVAI-open computes images through DirectML for now.</sub>

On the same card, DirectML was 2 to 6 times slower than CUDA, and Vulkan 1.7 times slower for video and about twice
as fast as DirectML for images. On the NVIDIA card both used its matrix units; an older Radeon has none, so expect its
times to be longer; how much longer has not been measured yet.

![Somi through DirectML: a banquet for one with a single plate of carrots, and Somi in a hooded cloak in a sunflower field](images/directml-somi.jpg)

<sub>Somi through DirectML with Juggernaut XL: a banquet for one, and a hooded walk through the sunflower field. Without a
LoRA for SDXL he is drawn from the description alone.</sub>

## How it works

- torch-directml exists only for PyTorch 2.4.1, and ComfyUI removed DirectML in version 0.46.0. NVAI-open therefore
  keeps a second environment for the image ComfyUI (`external\comfyui\.venv-directml`) and adds DirectML back into
  ComfyUI before each start; without DirectML nothing changes.
- ComfyUI's old DirectML code assumed 1 GB of memory and kept every model loaded (SDXL took 13.6 GB). NVAI-open asks
  Windows for the memory budget of the process instead, so models are swapped as with CUDA, and the VAE decodes in tiles
  when it would not fit.
- DirectML queues work far ahead and keeps the memory of each queued step until it has run; without regular syncs SDXL
  swung between 6 and 15 GB. With them it took at most 8.5 GB, and it is faster.
- Text encoders run on the processor (DirectML cannot handle FP8 weights), and 3D convolutions are computed as 2D ones.
- Each video is one run of stable-diffusion.cpp (`external\sdcpp\sd-cli.exe`); its log is `sdcpp.log` in the data
  folder, and "Report a problem" includes it.
- `NVAI_DIRECTML=0` as an environment variable switches DirectML off, `NVAI_SDCPP_ENGINE=0` the Vulkan engine.
