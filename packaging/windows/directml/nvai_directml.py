"""NVAI-open: DirectML mode for Radeons that AMD's PyTorch for Windows (ROCm) does not support (RX 5000, Vega,
Polaris). Lives in ComfyUI's DirectML venv (``external/comfyui/.venv-directml``) and is loaded by
``nvai_directml.pth`` at interpreter start.

1. PyTorch 2.4.1 compatibility (torch-directml exists only for 2.4.1): newer packages such as comfy-kitchen declare
   custom ops with PEP 585 hints (``list[int]``) or as strings (``from __future__ import annotations``), which
   PyTorch 2.4.1 rejects. As soon as ``torch._library.infer_schema`` is imported, its tables learn the PEP 585
   spellings and string hints are evaluated first, as newer PyTorch does. torch itself is not imported here.
2. Memory figures for ComfyUI's DirectML code (added back by NVAI-open, see server/nvai/directml.py): the card's
   dedicated memory and what this process may still use, from DXGI (IDXGIAdapter3::QueryVideoMemoryInfo: the budget
   Windows gives the process and its current use) plus the free part of torch-directml's memory pool. DirectML exceeds
   the budget silently: Windows then moves memory to the slower system RAM, and only far beyond it does an
   allocation fail. With these figures ComfyUI swaps and partly loads models as on CUDA.
"""
import collections.abc
import ctypes
import importlib.abc
import os
import sys
import typing

# --------------------------------------------------------------------------------------------- PyTorch 2.4.1

_TARGET = "torch._library.infer_schema"


def _alternatives(t):
    """PEP 585 spellings of a typing hint: List[X] -> list[X], Sequence[X] -> collections.abc.Sequence[X]."""
    origin = typing.get_origin(t)
    args = typing.get_args(t)
    out = []
    if origin is typing.Union:
        inner = [a for a in args if a is not type(None)]
        if len(inner) == 1 and len(args) == 2:
            out += [typing.Optional[alt] for alt in _alternatives(inner[0])]
        return out
    if origin in (list, collections.abc.Sequence) and len(args) == 1:
        for a in [args[0], *_alternatives(args[0])]:
            out += [list[a], collections.abc.Sequence[a]]
    return out


def _resolved(fn):
    """The function with string hints evaluated (PyTorch 2.4.1 compares the strings with its tables)."""
    import inspect
    try:
        sig = inspect.signature(fn)
    except (TypeError, ValueError):
        return fn
    if not any(isinstance(p.annotation, str) for p in sig.parameters.values()) \
            and not isinstance(sig.return_annotation, str):
        return fn
    try:
        hints = typing.get_type_hints(fn)
    except Exception:
        return fn
    params = [p.replace(annotation=hints.get(p.name, p.annotation)) for p in sig.parameters.values()]
    new_sig = sig.replace(parameters=params, return_annotation=hints.get("return", sig.return_annotation))

    def proxy(*args, **kwargs):
        return fn(*args, **kwargs)

    proxy.__signature__ = new_sig
    proxy.__name__ = getattr(fn, "__name__", "proxy")
    proxy.__qualname__ = getattr(fn, "__qualname__", proxy.__name__)
    proxy.__module__ = getattr(fn, "__module__", __name__)
    return proxy


def _patch_infer_schema(module):
    for table in ("SUPPORTED_PARAM_TYPES", "SUPPORTED_RETURN_TYPES"):
        types = getattr(module, table, None)
        if isinstance(types, dict):
            for key, schema in list(types.items()):
                for alt in _alternatives(key):
                    types.setdefault(alt, schema)
    original = getattr(module, "infer_schema", None)
    if callable(original) and not getattr(original, "_nvai", False):
        # replaced before torch._custom_op.impl and torch.library bind the name ("from ... import infer_schema")
        def infer_schema(prototype_function, *args, **kwargs):
            return original(_resolved(prototype_function), *args, **kwargs)

        infer_schema._nvai = True
        module.infer_schema = infer_schema


def _patch_custom_ops(module):
    """PyTorch 2.4.1 checks after every custom op (comfy-kitchen's RoPE, norms ...) that no output aliases an input,
    by comparing tensor.untyped_storage(). DirectML tensors have no accessible storage ("Cannot access storage of
    OpaqueTensorImpl": Stable Audio 3 and Wan failed there), so the check skips them; newer PyTorch checks differently."""
    original = getattr(module, "iter_tensors", None)
    if not callable(original) or getattr(original, "_nvai", False):
        return

    def iter_tensors(*args, **kwargs):
        for tensor in original(*args, **kwargs):
            device = getattr(tensor, "device", None)
            if device is not None and device.type == "privateuseone":
                continue
            yield tensor

    iter_tensors._nvai = True
    module.iter_tensors = iter_tensors


def _triple(v):
    return tuple(v) if isinstance(v, (tuple, list)) else (v, v, v)


def conv3d_as_2d(input, weight, bias=None, stride=1, padding=0, dilation=1, groups=1):
    """3D convolution as a sum of 2D convolutions over the time taps (torch-directml has no 3D convolution:
    "input must be 4-dimensional"; Wan's patch embedding and the video VAEs need it). Same result as conv3d."""
    import torch
    import torch.nn.functional as F
    st, sh, sw = _triple(stride)
    pt, ph, pw = _triple(padding)
    dt, dh, dw = _triple(dilation)
    if pt:
        input = F.pad(input, (0, 0, 0, 0, pt, pt))
    n, c, t = input.shape[:3]
    kt = weight.shape[2]
    t_out = (t - dt * (kt - 1) - 1) // st + 1
    out = None
    for k in range(kt):
        frames = input[:, :, k * dt: k * dt + st * (t_out - 1) + 1: st]
        flat = frames.transpose(1, 2).reshape(n * t_out, c, *frames.shape[3:])
        y = F.conv2d(flat, weight[:, :, k], None, (sh, sw), (ph, pw), (dh, dw), groups)
        out = y if out is None else out + y
        del frames, flat
    out = out.reshape(n, t_out, *out.shape[1:]).transpose(1, 2)
    if bias is not None:
        out = out + bias.view(1, -1, 1, 1, 1)
    return out.contiguous()


def _patch_functional(module):
    """torch.nn.functional.conv3d: DirectML tensors go through conv3d_as_2d (nn.Conv3d calls F.conv3d by name)."""
    original = getattr(module, "conv3d", None)
    if not callable(original) or getattr(original, "_nvai", False):
        return

    def conv3d(input, weight, bias=None, stride=1, padding=0, dilation=1, groups=1):
        if getattr(input, "device", None) is not None and input.device.type == "privateuseone" \
                and not isinstance(padding, str) and input.dim() == 5:
            return conv3d_as_2d(input, weight, bias, stride, padding, dilation, groups)
        return original(input, weight, bias, stride, padding, dilation, groups)

    conv3d._nvai = True
    conv3d.__doc__ = original.__doc__
    module.conv3d = conv3d


_PATCHES = {_TARGET: _patch_infer_schema, "torch._library.custom_ops": _patch_custom_ops}
if os.environ.get("NVAI_DML_CONV3D", "1") != "0":
    _PATCHES["torch.nn.functional"] = _patch_functional


class _Finder(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path, target=None):
        if fullname not in _PATCHES:
            return None
        spec = None
        for finder in sys.meta_path:
            if finder is self or not hasattr(finder, "find_spec"):
                continue
            spec = finder.find_spec(fullname, path, target)
            if spec is not None:
                break
        if spec is None or spec.loader is None or not hasattr(spec.loader, "exec_module"):
            return spec
        original = spec.loader.exec_module

        def exec_module(module, _original=original, _patch=_PATCHES[fullname]):
            _original(module)
            try:
                _patch(module)
            except Exception:  # never stop PyTorch from loading
                pass

        spec.loader.exec_module = exec_module
        return spec


if not any(type(f).__name__ == "_Finder" and type(f).__module__ == __name__ for f in sys.meta_path):
    sys.meta_path.insert(0, _Finder())

# --------------------------------------------------------------------------------------------- DXGI memory

MB = 1024 * 1024


class _GUID(ctypes.Structure):
    _fields_ = [("Data1", ctypes.c_uint32), ("Data2", ctypes.c_uint16), ("Data3", ctypes.c_uint16),
                ("Data4", ctypes.c_ubyte * 8)]


def _guid(s):
    import uuid
    u = uuid.UUID(s)
    g = _GUID()
    g.Data1, g.Data2, g.Data3 = u.fields[0], u.fields[1], u.fields[2]
    g.Data4[:] = list(u.bytes[8:])
    return g


class _LUID(ctypes.Structure):
    _fields_ = [("LowPart", ctypes.c_uint32), ("HighPart", ctypes.c_int32)]


class _DESC1(ctypes.Structure):
    _fields_ = [("Description", ctypes.c_wchar * 128), ("VendorId", ctypes.c_uint), ("DeviceId", ctypes.c_uint),
                ("SubSysId", ctypes.c_uint), ("Revision", ctypes.c_uint), ("DedicatedVideoMemory", ctypes.c_size_t),
                ("DedicatedSystemMemory", ctypes.c_size_t), ("SharedSystemMemory", ctypes.c_size_t),
                ("AdapterLuid", _LUID), ("Flags", ctypes.c_uint)]


class _MEMINFO(ctypes.Structure):
    _fields_ = [("Budget", ctypes.c_uint64), ("CurrentUsage", ctypes.c_uint64),
                ("AvailableForReservation", ctypes.c_uint64), ("CurrentReservation", ctypes.c_uint64)]


_IID_FACTORY1 = _guid("770aae78-f26f-4dba-a829-253c83d1b387")
_IID_ADAPTER3 = _guid("645967a4-1392-4310-a798-8053ce3e93fd")


def _call(obj, index, *argtypes):
    vtbl = ctypes.cast(obj, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p))).contents
    return ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_void_p, *argtypes)(vtbl[index])


def _release(obj):
    if obj:
        vtbl = ctypes.cast(obj, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p))).contents
        ctypes.WINFUNCTYPE(ctypes.c_ulong, ctypes.c_void_p)(vtbl[2])(obj)


def adapters():
    """[{"name", "dedicated", "budget", "usage"}] for every DXGI adapter; budget and usage apply to this process
    (None if the adapter has no IDXGIAdapter3). Empty list off Windows or on any error."""
    out = []
    if os.name != "nt":
        return out
    factory = ctypes.c_void_p()
    try:
        if ctypes.windll.dxgi.CreateDXGIFactory1(ctypes.byref(_IID_FACTORY1), ctypes.byref(factory)) != 0:
            return out
        i = 0
        while i < 16:
            adapter = ctypes.c_void_p()
            # IDXGIFactory1::EnumAdapters1, vtable slot 12 (IUnknown 3, IDXGIObject 4, IDXGIFactory 5)
            if _call(factory, 12, ctypes.c_uint, ctypes.POINTER(ctypes.c_void_p))(factory, i, ctypes.byref(adapter)):
                break
            try:
                desc = _DESC1()
                _call(adapter, 10, ctypes.POINTER(_DESC1))(adapter, ctypes.byref(desc))  # GetDesc1
                entry = {"name": desc.Description.rstrip("\x00"), "dedicated": int(desc.DedicatedVideoMemory),
                         "budget": None, "usage": None}
                a3 = ctypes.c_void_p()
                if _call(adapter, 0, ctypes.POINTER(_GUID), ctypes.POINTER(ctypes.c_void_p))(
                        adapter, ctypes.byref(_IID_ADAPTER3), ctypes.byref(a3)) == 0:
                    try:
                        info = _MEMINFO()
                        # IDXGIAdapter3::QueryVideoMemoryInfo, slot 14; segment group 0 = local (dedicated)
                        if _call(a3, 14, ctypes.c_uint, ctypes.c_int, ctypes.POINTER(_MEMINFO))(
                                a3, 0, 0, ctypes.byref(info)) == 0:
                            entry["budget"], entry["usage"] = int(info.Budget), int(info.CurrentUsage)
                    finally:
                        _release(a3)
                out.append(entry)
            finally:
                _release(adapter)
            i += 1
    except Exception:
        return out
    finally:
        _release(factory)
    return out


_state = {"index": 0, "name": ""}


def device(index=-1):
    """torch-directml device. index < 0: the DirectML adapter with the most dedicated memory (not an integrated
    Radeon or the Basic Render Driver), else torch-directml's default."""
    import torch_directml
    if index is None or index < 0:
        names = [torch_directml.device_name(i).rstrip("\x00") for i in range(torch_directml.device_count())]
        sizes = {a["name"]: a["dedicated"] for a in adapters()}
        ranked = sorted(range(len(names)), key=lambda i: sizes.get(names[i], 0), reverse=True)
        index = ranked[0] if ranked and sizes.get(names[ranked[0]], 0) > 0 else torch_directml.default_device()
    _state["index"] = index
    _state["name"] = torch_directml.device_name(index).rstrip("\x00")
    return torch_directml.device(index)


def label():
    a = _adapter()
    if a and a.get("dedicated"):
        return f"{_state['name']} ({a['dedicated'] // MB} MB)"
    return _state["name"]


def _adapter():
    for a in adapters():
        if a["name"] == _state["name"]:
            return a
    return None


def _env_mb(name):
    try:
        v = float(os.environ.get(name) or 0)
    except ValueError:
        return 0
    return int(v * MB) if v > 0 else 0


def total_memory():
    """Dedicated memory of the card (DXGI); NVAI_DML_VRAM_MB as fallback, then ComfyUI's old 1 GB."""
    a = _adapter()
    total = a["dedicated"] if a and a.get("dedicated") else _env_mb("NVAI_DML_VRAM_MB") or 1024 * MB
    cap = _env_mb("NVAI_DML_BUDGET_MB")  # for tests: behave like a smaller card
    return min(total, cap) if cap else total


def pool():
    """(size, used) of torch-directml's memory pool, read in 16-MB tiles with the used share of each."""
    try:
        import torch_directml
        tiles = torch_directml.gpu_memory(_state["index"], 16)
        return len(tiles) * 16 * MB, int(sum(tiles) * 16 * MB)
    except Exception:
        return 0, 0


def free_memory():
    """(free for new loads, free inside the pool). From the Windows budget for this process when DXGI answers,
    else from the card's size minus the pool's use and NVAI_DML_RESERVE_MB (default 768) for Windows.

    DirectML runs behind Python and every queued operation holds its memory from the moment it is queued; a tensor
    freed while its work is still queued is reused only after the queue has run. ComfyUI asks for free memory at
    every step and in every attention block, so the queue is flushed here first: the figure is then true, and the
    pile-up stays within one block (without it SDXL swung between 6 and 15 GB)."""
    sync()
    size, used = pool()
    pool_free = max(0, size - used)
    a = _adapter()
    cap = _env_mb("NVAI_DML_BUDGET_MB")
    if a and a.get("budget") is not None:
        budget = min(a["budget"], cap) if cap else a["budget"]
        # usage counts the whole pool; its free part is reusable. Over budget (DirectML overcommits silently) the
        # overrun is subtracted first: max(0, budget - usage) + pool_free reported 13 GB free on a 7.7-GB budget.
        return max(0, budget - a["usage"] + pool_free), pool_free
    reserve = _env_mb("NVAI_DML_RESERVE_MB") or 768 * MB
    return max(0, total_memory() - reserve - used), pool_free


def sync():
    """Flush DirectML's queue: tensors freed while their work was still queued count as free only afterwards."""
    try:
        import torch
        import torch_directml
        torch.zeros(1, device=torch_directml.device(_state["index"])).cpu()
    except Exception:
        pass
