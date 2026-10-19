# Machbarkeitstest TRELLIS.2-4B in EIGENEM venv.
#
# Bewusst getrennt von ComfyUI (torch 2.11+cu128) und TripoSG: die vorgebauten
# CUDA-Extensions sind gegen torch 2.10 + cu130 gebaut, und CUDA-Extensions
# vertragen keine ABI-Abweichung.
#
# uv schreibt Statusmeldungen auf stderr; mit ErrorActionPreference "Stop" wuerde
# PowerShell 5.1 das als NativeCommandError behandeln. Deshalb Exit-Codes selbst pruefen.
$ErrorActionPreference = "Continue"
$repo = Split-Path -Parent $PSScriptRoot
$t2 = Join-Path $repo "external\trellis2"

if (-not (Test-Path $t2)) { throw "TRELLIS.2-Repo fehlt unter $t2" }

$venv = Join-Path $t2 ".venv"
$py = Join-Path $venv "Scripts\python.exe"

function Step($label) { Write-Host "`n== $label ==" -ForegroundColor Cyan }
function Check($label) {
    if ($LASTEXITCODE -ne 0) { throw "$label fehlgeschlagen (Exit $LASTEXITCODE)" }
}

Step "venv (Python 3.12)"
uv venv --python 3.12 --clear $venv
Check "venv"

# Die Wheels tragen den Tag cu130torch2.10.0 -- exakt diese Kombination noetig.
Step "PyTorch 2.10 + CUDA 13.0"
uv pip install --python $py torch==2.10.0 torchvision --index-url https://download.pytorch.org/whl/cu130
Check "PyTorch"

# pillow-simd, gradio und tensorboard aus setup.sh weggelassen: auf Windows nicht
# baubar bzw. nur fuer Demo-UI und Training noetig.
Step "Basis-Abhaengigkeiten"
# einops wird von BiRefNet (trust_remote_code) gebraucht, fastapi/uvicorn vom Worker.
uv pip install --python $py imageio imageio-ffmpeg tqdm easydict opencv-python-headless ninja trimesh transformers zstandard kornia timm pillow numpy scipy einops fastapi "uvicorn[standard]" pydantic
Check "Basis"

Step "utils3d"
uv pip install --python $py "git+https://github.com/EasternJournalist/utils3d.git@9a4eb15e4021b67b12c460c7057d642626897ec8"
Check "utils3d"

Step "Check"
& $py -c "import torch; print('torch', torch.__version__); print('cuda', torch.cuda.is_available()); print('arch', torch.cuda.get_device_capability(0) if torch.cuda.is_available() else 'n/a')"

Write-Host "`nBasis steht." -ForegroundColor Green
