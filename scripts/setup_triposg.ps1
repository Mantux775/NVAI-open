# Richtet den TripoSG-Worker in einem EIGENEN venv ein.
# Bewusst getrennt von ComfyUI: TripoSG braucht andere diffusers/numpy-Versionen.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$tri = Join-Path $repo "external\triposg"

if (-not (Test-Path $tri)) { throw "TripoSG-Repo fehlt unter $tri" }

Write-Host "== venv (Python 3.12) ==" -ForegroundColor Cyan
uv venv --python 3.12 (Join-Path $tri ".venv")
$py = Join-Path $tri ".venv\Scripts\python.exe"

Write-Host "== PyTorch (CUDA 12.8, Blackwell) ==" -ForegroundColor Cyan
uv pip install --python $py torch torchvision --index-url https://download.pytorch.org/whl/cu128

# numpy==1.22.3 aus requirements.txt ist fuer Python 3.12 zu alt und wird ignoriert.
# diso wird separat versucht -- es ist eine CUDA-Extension und nur fuer den
# flash_extract_geometry-Pfad noetig, den wir nicht benutzen.
Write-Host "== TripoSG-Abhaengigkeiten ==" -ForegroundColor Cyan
uv pip install --python $py `
    diffusers transformers einops huggingface_hub `
    opencv-python trimesh omegaconf scikit-image `
    peft jaxtyping typeguard pymeshlab `
    "numpy>=1.26,<2.3" fastapi "uvicorn[standard]" pillow

Write-Host "== Check ==" -ForegroundColor Cyan
& $py -c "import torch, diffusers, trimesh, skimage; print('torch', torch.__version__, 'cuda', torch.cuda.is_available()); print('diffusers', diffusers.__version__)"

Write-Host "`nFertig." -ForegroundColor Green
