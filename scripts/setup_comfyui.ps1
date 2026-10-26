# Richtet das ComfyUI-Backend in einem EIGENEN venv ein.
# Getrennt vom Server-venv, damit Torch-Dependencies nichts anderes zerlegen.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$comfy = Join-Path $repo "external\comfyui"

if (-not (Test-Path $comfy)) { throw "ComfyUI fehlt unter $comfy" }

Write-Host "== venv (Python 3.12) ==" -ForegroundColor Cyan
uv venv --python 3.12 (Join-Path $comfy ".venv")
$py = Join-Path $comfy ".venv\Scripts\python.exe"

# RTX 50-Serie ist Blackwell / sm_120: aeltere Torch-Builds ohne cu128 werfen
# "no kernel image is available for execution on the device".
# cu130 statt cu128: darunter schaltet ComfyUI das CUDA-Backend von comfy_kitchen ab.
# NVFP4 laeuft dann ueber den eager-Pfad, dessen Aktivierungs-Quantisierung den
# FP4-Vorteil komplett auffrisst (gemessen 5,9 statt 0,18 ms je 4096x3072-Block).
# Braucht einen Treiber ab 580.
Write-Host "== PyTorch (CUDA 13.0, Blackwell) ==" -ForegroundColor Cyan
# Ohne torchaudio: ComfyUI 0.42.1 und NVAI-open importieren es nicht, und fuer cu130 gibt es es nur bis 2.11
# (ABI passt nicht zu torch 2.14). Das Setup nimmt die getestete Fassung aus packaging/windows/locks/comfyui.lock.
uv pip install --python $py torch torchvision --index-url https://download.pytorch.org/whl/cu130

Write-Host "== ComfyUI-Requirements ==" -ForegroundColor Cyan
uv pip install --python $py -r (Join-Path $comfy "requirements.txt")

Write-Host "== Check ==" -ForegroundColor Cyan
& $py -c "import torch; print('torch', torch.__version__); print('cuda', torch.cuda.is_available()); print('device', torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'n/a'); print('capability', torch.cuda.get_device_capability(0) if torch.cuda.is_available() else 'n/a')"

Write-Host "`nFertig. Start: scripts\start.ps1" -ForegroundColor Green
