"""Macht o-voxel MSVC-tauglich.

Der Quellcode ist fuer GCC/Linux geschrieben. Zwei Inkompatibilitaeten:

1. Fliesskomma-Literale mit 'd'-Suffix (1e-6d, 0.0d). Das ist KEIN gueltiges C++ --
   GCC erlaubt es als Erweiterung, MSVC lehnt es ab (C3688). Suffix entfernen;
   double ist der Standardtyp fuer Fliesskomma-Literale, die Semantik bleibt gleich.

2. torch::zeros({N, C}) mit size_t-Variablen. Die Initializer-List erwartet int64_t,
   und MSVC verbietet die verengende Konvertierung (C2398). Expliziter Cast.

Idempotent: mehrfaches Ausfuehren aendert nichts.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = (Path(sys.argv[1]) if len(sys.argv) > 1
        else Path(__file__).resolve().parents[1] / "external" / "trellis2" / "o-voxel")

# Nur echte Fliesskomma-Literale: 1.5d, .5d, 1e-6d, 1E+3d -- niemals Bezeichner wie grid3d.
FLOAT_D = re.compile(r"(?<![\w.])(\d+\.\d*|\.\d+|\d+(?=[eE]))([eE][+-]?\d+)?d\b")


def fix_float_suffix(text: str) -> tuple[str, int]:
    def repl(m: re.Match) -> str:
        return m.group(0)[:-1]  # nur das abschliessende 'd' entfernen

    new, n = FLOAT_D.subn(repl, text)
    return new, n


def fix_narrowing(text: str) -> tuple[str, int]:
    # torch::zeros({N, C}) -> torch::zeros({(int64_t)N, (int64_t)C})
    # Auch from_blob({vec.size()}) -- Groessenangaben sind size_t, erwartet wird int64_t.
    pattern = re.compile(r"(torch::(?:zeros|empty|ones|from_blob)\([^{]*\{)([^}]+)(\})")

    count = 0
    # Bezeichner oder einfacher Aufruf wie vec.size(); keine komplexen Ausdruecke.
    SAFE = re.compile(r"[A-Za-z_]\w*(?:\.\w+\(\))?")

    def repl(m: re.Match) -> str:
        nonlocal count
        inner = m.group(2)
        if "int64_t" in inner:
            return m.group(0)
        parts = [p.strip() for p in inner.split(",")]
        if not all(SAFE.fullmatch(p) for p in parts):
            return m.group(0)
        count += 1
        return m.group(1) + ", ".join(f"(int64_t){p}" for p in parts) + m.group(3)

    return pattern.sub(repl, text), count


def fix_dependent_template(text: str) -> tuple[str, int]:
    """`obj.data_ptr<T>()` -> `obj.template data_ptr<T>()`.

    Wenn T ein Template-Parameter ist, verlangt der C++-Standard das
    template-Keyword. GCC akzeptiert es auch ohne, MSVC/EDG melden
    "type name is not allowed".
    """
    return re.subn(
        r"(?<!template )\.data_ptr<(T|scalar_t|index_t)>\(\)",
        r".template data_ptr<\1>()",
        text,
    )


GUARDED_INCLUDE = """#ifdef __CUDACC__
// Beim Uebersetzen von .cu-Dateien bindet CUDA seine eigene cuda::std-Bibliothek
// ein. torch/extension.h zieht compiled_autograd.h nach, und MSVC meldet dann
// "std" als mehrdeutig (C2872). Kernel brauchen nur die Tensor-Typen.
#include <torch/types.h>
#else
#include <torch/extension.h>
#endif"""


def fix_cuda_includes(text: str, is_cu: bool) -> tuple[str, int]:
    """torch/extension.h in .cu direkt, in Headern bedingt ersetzen.

    Header werden sowohl von .cpp (brauchen pybind) als auch von .cu eingebunden --
    deshalb dort die __CUDACC__-Weiche statt eines harten Austauschs.
    """
    if "torch/extension.h" not in text or "__CUDACC__" in text:
        return text, 0
    if is_cu:
        return re.subn(
            r"#include\s*<torch/extension\.h>",
            "#include <torch/types.h>  // statt extension.h: vermeidet C2872 in .cu",
            text,
        )
    return re.subn(r"#include\s*<torch/extension\.h>", GUARDED_INCLUDE, text)


total_d = total_n = total_i = total_t = 0
for path in sorted(ROOT.rglob("*")):
    if path.suffix not in (".cpp", ".cu", ".h", ".hpp", ".cuh") or "third_party" in path.parts:
        continue
    original = path.read_text(encoding="utf-8", errors="replace")
    text, n_d = fix_float_suffix(original)
    text, n_n = fix_narrowing(text)
    text, n_i = fix_cuda_includes(text, path.suffix in (".cu", ".cuh"))
    text, n_t = fix_dependent_template(text)
    if text != original:
        path.write_text(text, encoding="utf-8")
        print(f"  {path.relative_to(ROOT)}: {n_d} Suffixe, {n_n} Casts, "
              f"{n_i} Includes, {n_t} template-Keywords")
        total_d += n_d
        total_n += n_n
        total_i += n_i
        total_t += n_t

print(f"\nGesamt: {total_d} 'd'-Suffixe, {total_n} narrowing-Casts, "
      f"{total_i} Include-Umstellungen, {total_t} template-Keywords")

