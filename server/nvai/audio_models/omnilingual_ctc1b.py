"""Omnilingual ASR CTC 1B v2 (Meta FAIR, Dezember 2025; Code und Gewichte Apache-2.0): Spracherkennung für über 1600
Sprachen, hier als zweite Meinung neben Whisper für Tagalog/Filipino und Cebuano. Liefert Text mit Groß- und
Kleinschreibung und Satzzeichen („written“-Tokenizer v2), Wortzeiten und Wort-Wahrscheinlichkeiten und richtet einen
fremden Text (etwa den von Whisper) per CTC-Viterbi am Ton aus.

Ohne fairseq2 (läuft nicht unter Windows): Der Checkpoint ist ein reines state_dict in fp32 (torch.load mit
weights_only=True genügt, das Pickle enthält keine fairseq2-Klassen). Beim ersten load() wird er auf
transformers.Wav2Vec2ForCTC umbenannt (gleiche Architektur: XLS-R-artiger Encoder mit LayerNorm in den Faltungen,
48 Schichten zu 1280, Pre-LN, Faltungs-Positionen 128/16, CTC-Kopf über 10 288 Zeichen) und als fp16-safetensors unter
hf/ neben die Originale gelegt. Blank ist Index 0 (<s>) wie bei ctc_loss in fairseq2, das Leerzeichen ist ein eigenes
Zeichen.

Wie die Original-Pipeline (omnilingual_asr.models.inference.pipeline): 16 kHz mono, je Stück auf Mittelwert 0 und
Varianz 1 normiert (layer_norm über die Wellenform), gierige CTC-Dekodierung. Das Original nimmt höchstens 40 s am
Stück; längere Aufnahmen laufen hier in Fenstern von 30 s, von denen die letzten 8 s nie gelten (dort entgleist das
Modell, wenn das Fenster mitten in der Sprache endet; Einzelheiten in _run), geschnitten wird an Pausen. Im Speicher
bleibt je Bild (20 ms) nur das Nötige: beim Erkennen bestes Zeichen und die Wahrscheinlichkeiten von Zeichen und
Blank, beim Ausrichten die Spalten der Zeichen des Textes. Damit bleibt der Speicher auch bei Stunden klein.

Schnittstelle (audio_16k: float32, mono, 16 kHz; (Proben,) oder (Proben, 1)):
  load(weights_dir, device, params) -> bundle            params: precision fp16 | bf16 | fp32
  transcribe(bundle, audio_16k, params) -> {"text", "words": [[start_s, end_s, wort, p], …], "logprob"}
  align(bundle, audio_16k, text, params) -> [[start_s, end_s, wort, p], …]   (je Wort des Textes ein Eintrag)
Wort-Wahrscheinlichkeit p: je Zeichen die Wahrscheinlichkeit des Modells für genau dieses Zeichen auf seinen Bildern
(Spitzenwert), davon das schwächste Zeichen des Wortes (WORD_PROB „min“; „mean“ mittelt). Gemessen an FLEURS Tagalog
(17.11.2026): „min“ trennt richtige von falschen Wörtern besser (AUROC eigene Erkennung 0,85 statt 0,84, Whisper-Text
ausgerichtet 0,83 statt 0,81). Das Modell ist sehr sicher: Wörter mit p ≥ 0,99 sind zu ~3 % falsch, 0,9–0,99 zu ~10 %,
0,5–0,9 zu ~30–45 %, unter 0,5 zu ~60–95 %. Zahlen und Messreihe: notizen/omnilingual.md.
"""
from __future__ import annotations

import json
import math
import os
import re
import unicodedata
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any, Callable

import numpy as np

SAMPLE_RATE = 16000
CHANNELS = 1
STEMS: list[str] = []          # liefert Text, keine Spuren
CHUNK_SECONDS = 30.0           # Fensterlänge für lange Aufnahmen
OVERLAP_SECONDS = 10.0         # Schutzabstand + Vorlauf (für Aufrufer, die selbst Fenster schneiden)
SINGLE_MAX_SECONDS = 40.0      # bis hierhin in einem Stück (Grenze der Original-Pipeline)
GUARD_SECONDS = 8.0            # so viel vom Fensterende bleibt ungenutzt (Entgleisen bei hartem Ende, siehe _run)
CONTEXT_SECONDS = 2.0          # Vorlauf des nächsten Fensters vor dem Schnitt
PAUSE_WORD_SECONDS = 0.5       # längere Pause zwischen zwei Zeichen = Wortgrenze, auch ohne Leerzeichen

CHECKPOINT = "omniASR-CTC-1B-v2.pt"
TOKENIZER = "omniASR_tokenizer_written_v2.model"
CACHE = "hf"                   # umgeschriebene Gewichte neben den Originalen
CONVERTER_VERSION = 1
PRECISION = "fp16"             # Grafikkarte; auf der CPU immer fp32 (bf16 gemessen gleich gut)
WORD_PROB = "min"              # schwächstes Zeichen des Wortes (gemessen besser als der Mittelwert)

HOP = 320                      # Proben je Ausgabebild (Schritte 5·2·2·2·2·2·2)
FRAME_SECONDS = HOP / SAMPLE_RATE
BLANK = 0                      # <s>: CTC-Blank (fairseq2 ctc_loss, blank=0)
WILD = -1                      # Platzhalter beim Ausrichten (Zahl, unbekanntes Zeichen)
WILD_COST = 0.3                # Platzhalter kostet je Bild so viele nat: deckt den gesprochenen Teil, nicht die Pausen
MAX_CELLS = 120_000_000        # Viterbi in einem Stück bis Bilder × Zustände; darüber in Abschnitten an sicheren Wörtern
PIECE_SECONDS = 60.0           # Abschnittslänge beim Ausrichten langer Aufnahmen
SKIP_PENALTY: float | None = 15.0  # Wort darf beim Ausrichten fehlen, Übersprung kostet so viele nat (None = nie);
                                   # an FLEURS ohne Unterschied, schützt die Nachbarn erfundener Wörter

# fairseq2-Namen -> transformers.Wav2Vec2ForCTC
_RENAME = [
    (r"^encoder_frontend\.feature_extractor\.layers\.(\d+)\.conv\.", r"wav2vec2.feature_extractor.conv_layers.\1.conv."),
    (r"^encoder_frontend\.feature_extractor\.layers\.(\d+)\.layer_norm\.",
     r"wav2vec2.feature_extractor.conv_layers.\1.layer_norm."),
    (r"^encoder_frontend\.post_extract_layer_norm\.", r"wav2vec2.feature_projection.layer_norm."),
    (r"^encoder_frontend\.model_dim_proj\.", r"wav2vec2.feature_projection.projection."),
    (r"^encoder_frontend\.pos_encoder\.conv\.weight_g$", r"wav2vec2.encoder.pos_conv_embed.conv.parametrizations.weight.original0"),
    (r"^encoder_frontend\.pos_encoder\.conv\.weight_v$", r"wav2vec2.encoder.pos_conv_embed.conv.parametrizations.weight.original1"),
    (r"^encoder_frontend\.pos_encoder\.conv\.bias$", r"wav2vec2.encoder.pos_conv_embed.conv.bias"),
    (r"^encoder\.layers\.(\d+)\.self_attn_layer_norm\.", r"wav2vec2.encoder.layers.\1.layer_norm."),
    (r"^encoder\.layers\.(\d+)\.self_attn\.([qkv])_proj\.", r"wav2vec2.encoder.layers.\1.attention.\2_proj."),
    (r"^encoder\.layers\.(\d+)\.self_attn\.output_proj\.", r"wav2vec2.encoder.layers.\1.attention.out_proj."),
    (r"^encoder\.layers\.(\d+)\.ffn_layer_norm\.", r"wav2vec2.encoder.layers.\1.final_layer_norm."),
    (r"^encoder\.layers\.(\d+)\.ffn\.inner_proj\.", r"wav2vec2.encoder.layers.\1.feed_forward.intermediate_dense."),
    (r"^encoder\.layers\.(\d+)\.ffn\.output_proj\.", r"wav2vec2.encoder.layers.\1.feed_forward.output_dense."),
    (r"^encoder\.layer_norm\.", r"wav2vec2.encoder.layer_norm."),
    (r"^final_proj\.", r"lm_head."),
]
# Faltungen der Merkmals-Stufe in fairseq2 (Wav2Vec2EncoderConfig.feature_extractor_layer_descs, Vorgabe)
_CONV_KERNEL = (10, 3, 3, 3, 3, 2, 2)
_CONV_STRIDE = (5, 2, 2, 2, 2, 2, 2)


# ------------------------------------------------------------------------------------------------ Umschreiben

def _hf_config(sd: dict[str, Any]) -> dict[str, Any]:
    """Konfiguration aus den Formen der Gewichte (1B: 1280 breit, 48 Schichten, 5120 FFN, 10 288 Zeichen)."""
    dim = int(sd["final_proj.weight"].shape[1])
    layers = 1 + max(int(m.group(1)) for k in sd if (m := re.match(r"encoder\.layers\.(\d+)\.", k)))
    convs = sorted({int(m.group(1)) for k in sd
                    if (m := re.match(r"encoder_frontend\.feature_extractor\.layers\.(\d+)\.", k))})
    kernels = tuple(int(sd[f"encoder_frontend.feature_extractor.layers.{i}.conv.weight"].shape[2]) for i in convs)
    if kernels != _CONV_KERNEL:
        raise SystemExit(f"Omnilingual: unerwartete Faltungen {kernels}")
    v = sd["encoder_frontend.pos_encoder.conv.weight_v"]
    return {
        "architectures": ["Wav2Vec2ForCTC"], "model_type": "wav2vec2",
        "vocab_size": int(sd["final_proj.weight"].shape[0]), "hidden_size": dim, "num_hidden_layers": layers,
        "num_attention_heads": 16,  # alle Omnilingual-Größen (large_lv60k und Ableitungen): 16 Köpfe
        "intermediate_size": int(sd["encoder.layers.0.ffn.inner_proj.weight"].shape[0]),
        "hidden_act": "gelu", "feat_extract_norm": "layer", "feat_extract_activation": "gelu", "conv_bias": True,
        "conv_dim": [int(sd[f"encoder_frontend.feature_extractor.layers.{i}.conv.weight"].shape[0]) for i in convs],
        "conv_kernel": list(_CONV_KERNEL), "conv_stride": list(_CONV_STRIDE),
        "num_conv_pos_embeddings": int(v.shape[2]), "num_conv_pos_embedding_groups": dim // int(v.shape[1]),
        "do_stable_layer_norm": True, "layer_norm_eps": 1e-5,
        "hidden_dropout": 0.0, "activation_dropout": 0.0, "attention_dropout": 0.0, "feat_proj_dropout": 0.0,
        "final_dropout": 0.0, "layerdrop": 0.0, "apply_spec_augment": False, "mask_time_prob": 0.0,
        "mask_feature_prob": 0.0, "pad_token_id": BLANK, "bos_token_id": 0, "eos_token_id": 2,
        "ctc_loss_reduction": "sum", "ctc_zero_infinity": True, "add_adapter": False, "use_weighted_layer_sum": False,
    }


def _source_info(weights_dir: Path) -> dict[str, Any]:
    st = (weights_dir / CHECKPOINT).stat()
    return {"checkpoint": CHECKPOINT, "size": st.st_size, "mtime_ns": st.st_mtime_ns, "converter": CONVERTER_VERSION}


def convert(weights_dir: Path) -> Path:
    """fairseq2-Checkpoint -> hf/config.json + hf/model.safetensors (fp16). Schreibt erst unter Hilfsnamen, dann
    os.replace; ein zweiter Prozess, der gleichzeitig umschreibt, stört nicht."""
    import torch
    from safetensors.torch import save_file

    weights_dir = Path(weights_dir)
    src = weights_dir / CHECKPOINT
    if not src.is_file():
        raise SystemExit(f"Omnilingual: {CHECKPOINT} fehlt in {weights_dir}")
    out = weights_dir / CACHE
    out.mkdir(parents=True, exist_ok=True)
    ck = torch.load(str(src), map_location="cpu", weights_only=True, mmap=True)
    sd = ck["model"] if isinstance(ck, dict) and "model" in ck else ck
    cfg = _hf_config(sd)
    tensors: dict[str, Any] = {}
    for k, t in sd.items():
        new = k
        for pat, rep in _RENAME:
            new, n = re.subn(pat, rep, new)
            if n:
                break
        else:
            raise SystemExit(f"Omnilingual: unbekannter Gewichtsname {k}")
        t = t.detach().to(torch.float32)
        if not torch.isfinite(t).all() or float(t.abs().max()) > 60000:
            raise SystemExit(f"Omnilingual: {k} passt nicht in fp16")
        tensors[new] = t.to(torch.float16).contiguous()
    tag = f".{os.getpid()}.part"
    save_file(tensors, str(out / f"model.safetensors{tag}"), metadata={"format": "pt", "source": CHECKPOINT})
    (out / f"config.json{tag}").write_text(json.dumps(cfg, indent=1), encoding="utf-8")
    os.replace(out / f"model.safetensors{tag}", out / "model.safetensors")
    os.replace(out / f"config.json{tag}", out / "config.json")
    (out / "source.json").write_text(json.dumps(_source_info(weights_dir)), encoding="utf-8")
    return out


def _cache_ok(weights_dir: Path) -> bool:
    out = weights_dir / CACHE
    try:
        have = json.loads((out / "source.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    return (out / "model.safetensors").is_file() and (out / "config.json").is_file() and have == _source_info(weights_dir)


# ------------------------------------------------------------------------------------------------ Laden

class _Vocab:
    """Zeichentabelle des Tokenizers (SentencePiece, ein Zeichen je Eintrag; 0–3 sind <s> <pad> </s> <unk>)."""

    def __init__(self, path: Path) -> None:
        import sentencepiece as spm
        sp = spm.SentencePieceProcessor(model_file=str(path))
        self.size = sp.get_piece_size()
        self.pieces = [sp.id_to_piece(i) for i in range(self.size)]
        self.special = {i for i in range(self.size) if sp.is_control(i) or sp.is_unknown(i)}
        self.space = self.pieces.index(" ")
        self.punct = [i for i, p in enumerate(self.pieces)
                      if i not in self.special and len(p) == 1 and unicodedata.category(p)[0] == "P"]
        # Groß-/Kleinschreibung zusammenlegen: Kleinbuchstabe -> alle Einträge, die dazu werden
        self.fold: dict[str, list[int]] = {}
        for i, p in enumerate(self.pieces):
            if i in self.special or i == self.space or len(p) != 1:
                continue
            key = unicodedata.normalize("NFC", p).lower()
            key = key if len(key) == 1 else p
            self.fold.setdefault(key, []).append(i)


def load(weights_dir: Path, device: str, params: dict[str, Any]) -> dict[str, Any]:
    import torch
    from transformers import Wav2Vec2ForCTC

    weights_dir = Path(weights_dir)
    if not (weights_dir / TOKENIZER).is_file():
        raise SystemExit(f"Omnilingual: {TOKENIZER} fehlt in {weights_dir}")
    if not _cache_ok(weights_dir):
        convert(weights_dir)
    prec = str(params.get("precision") or PRECISION) if device == "cuda" else "fp32"
    dtype = {"fp16": torch.float16, "bf16": torch.bfloat16}.get(prec, torch.float32)
    model, info = Wav2Vec2ForCTC.from_pretrained(str(weights_dir / CACHE), dtype=dtype, attn_implementation="sdpa",
                                                 local_files_only=True, output_loading_info=True)
    bad = [k for k in ("missing_keys", "unexpected_keys", "mismatched_keys") if info.get(k)]
    if bad:
        raise SystemExit(f"Omnilingual: Gewichte passen nicht ({ {k: list(info[k])[:5] for k in bad} })")
    model.to(device).eval()
    vocab = _Vocab(weights_dir / TOKENIZER)
    if vocab.size != model.config.vocab_size:
        raise SystemExit(f"Omnilingual: Tokenizer ({vocab.size}) passt nicht zum Modell ({model.config.vocab_size})")
    return {"model": model, "device": device, "dtype": dtype, "precision": prec, "vocab": vocab}


# ------------------------------------------------------------------------------------------------ Rechnen

def _mono(audio: np.ndarray) -> np.ndarray:
    x = np.asarray(audio, dtype=np.float32)
    if x.ndim == 2:
        x = x.mean(axis=1) if x.shape[1] > 1 else x[:, 0]
    return np.ascontiguousarray(x)


def _n_frames(n: int) -> int:
    for k, s in zip(_CONV_KERNEL, _CONV_STRIDE):
        n = (n - k) // s + 1
        if n <= 0:
            return 0
    return n


def _logprobs(bundle: dict[str, Any], seg: np.ndarray) -> Any:
    """Ein Stück durchs Netz: (Bilder, 10 288) Log-Wahrscheinlichkeiten in fp32 auf dem Rechengerät."""
    import torch
    x = torch.from_numpy(seg).to(bundle["device"], torch.float32)
    x = torch.nn.functional.layer_norm(x, x.shape)  # wie apply_audio_normalization im Original
    with torch.inference_mode():
        logits = bundle["model"](x[None].to(bundle["dtype"])).logits[0]
        return torch.log_softmax(logits.float(), dim=-1)


def _run(bundle: dict[str, Any], audio: np.ndarray, params: dict[str, Any],
         reduce: Callable[[Any], np.ndarray]) -> np.ndarray:
    """Ton in Fenstern durchs Netz; reduce(logprobs (T, V)) -> np.ndarray (T, …) behält je Bild nur das Nötige.
    Gibt die zusammengesetzte Matrix über alle Bilder zurück.

    Bis SINGLE_MAX_SECONDS in einem Stück. Länger: Fenster von CHUNK_SECONDS. Endet ein Fenster mitten in der Sprache
    und steht davor schon eine andere Äußerung, entgleisen seine letzten Sekunden (gemessen an FLEURS-Paaren: bis
    ~5 s Unsinn, je nach Schnitt). Deshalb gilt von jedem Fenster nur, was mindestens GUARD_SECONDS vor seinem Ende
    liegt: Der Schnitt wird im Fenster an der spätesten Pause davor geplant (längste Blank-Strecke, ±100 ms), das
    nächste Fenster beginnt CONTEXT_SECONDS vor dem Schnitt, und der endgültige Schnitt fällt ±1 s um den geplanten
    dorthin, wo beide Fenster am sichersten Blank sehen. Fensteranfänge liegen auf Vielfachen von 320 Proben, damit
    die Bilder deckungsgleich sind. Mehraufwand rund das 1,5-Fache."""
    from scipy.ndimage import minimum_filter1d

    n = len(audio)
    if _n_frames(n) <= 0:
        return np.zeros((0,), np.float32)
    single = int(float(params.get("single_max_seconds") or SINGLE_MAX_SECONDS) * SAMPLE_RATE)
    chunk = int(float(params.get("chunk_seconds") or CHUNK_SECONDS) * SAMPLE_RATE) // HOP * HOP
    guard = int(float(params.get("guard_seconds") or GUARD_SECONDS) * SAMPLE_RATE) // HOP
    ctx = int(CONTEXT_SECONDS * SAMPLE_RATE) // HOP
    chunk = max(chunk, (guard + ctx + 5 * 50) * HOP)  # mindestens 5 s eigene Ausgabe je Fenster
    if n <= max(single, chunk):
        return reduce(_logprobs(bundle, audio))
    parts: list[np.ndarray] = []
    s = 0                       # Fensteranfang in Proben
    keep = 0                    # erstes eigenes Bild dieses Fensters (global)
    prev: list[Any] | None = None  # [erstes Bild, Daten, Blank-Wahrscheinlichkeit, geplanter Schnitt]
    while True:
        last = n - s <= single
        lp = _logprobs(bundle, audio[s:n if last else s + chunk])
        red = reduce(lp)
        pb = lp[:, BLANK].exp().cpu().numpy()
        off = s // HOP
        if prev is not None:
            p_off, p_red, p_pb, plan = prev
            a = max(off + ctx // 2, plan - 50, keep + 1)
            b = max(a + 1, min(plan + 50, p_off + len(p_red) - guard // 2, off + len(red)))
            both = np.minimum(p_pb[a - p_off:b - p_off], pb[a - off:b - off])
            c = a + int(np.argmax(minimum_filter1d(both, size=7, mode="nearest")
                                  - 1e-3 * np.abs(np.arange(a, b) - plan) / 50))
            parts.append(p_red[keep - p_off:c - p_off])
            keep = c
        if last:
            parts.append(red[keep - off:])
            return np.concatenate(parts)
        # Schnitt planen: späteste Pause zwischen Vorlauf + 10 s und Fensterende - Schutzabstand
        lo, hi = keep + 10 * 50, off + len(red) - guard
        lo = min(lo, hi - 1)
        score = minimum_filter1d(pb[lo - off:hi - off], size=11, mode="nearest")
        plan = lo + int(np.argmax(score + 0.05 * np.linspace(0.0, 1.0, hi - lo)))
        prev = [off, red, pb, plan]
        s = max(s + HOP, (plan - ctx) * HOP)


# ------------------------------------------------------------------------------------------------ Erkennen

def _word_prob(probs: list[float], how: str) -> float:
    if not probs:
        return 0.0
    return float(min(probs)) if how == "min" else float(np.mean(probs))


def _latin_mask(bundle: dict[str, Any]) -> Any:
    """Zeichen, die in lateinischer Schrift vorkommen (bis U+024F, dazu Apostroph und Bindestrich), plus Blank, Leerzeichen
    und Sonderzeichen. Das CTC-Modell hat keine Sprachvorgabe: Auf verrauschten Mikrofonen eines Schiffsschreibers gab es
    zu 59 % chinesische oder andere fremde Zeichen aus (17.11.2026), obwohl dort Tagalog und Englisch gesprochen werden."""
    import torch
    mask = bundle.get("_latin_mask")
    if mask is None:
        vocab: _Vocab = bundle["vocab"]
        keep = []
        for i, piece in enumerate(vocab.pieces):
            if i == BLANK or i == vocab.space or i in vocab.special:
                keep.append(True)
            else:
                keep.append(bool(piece) and all(ord(ch) <= 0x024F or ch in "\u2019\u2010\u2011" for ch in piece))
        mask = torch.tensor(keep, dtype=torch.bool)
        bundle["_latin_mask"] = mask
    return mask


def transcribe(bundle: dict[str, Any], audio: np.ndarray, params: dict[str, Any] | None = None) -> dict[str, Any]:
    """Gierige CTC-Dekodierung mit Wortzeiten. words: [start_s, end_s, wort, p] mit p = Spitzen-Wahrscheinlichkeit
    jedes Zeichens auf seinen Bildern, davon das schwächste des Wortes (params word_prob „mean“: Mittelwert). Wortenden
    liegen eher früh (CTC gibt jedes Zeichen am Anfang seines Lautes aus). logprob: mittlere Log-Wahrscheinlichkeit
    der ausgegebenen Zeichen (Bilder ohne Blank), je näher an 0, desto sicherer (gegen die Wortfehler je Satz:
    Spearman −0,39 bis −0,53). params offset_seconds verschiebt alle Zeiten (Abschnitt aus einer längeren Aufnahme)."""
    import torch

    params = params or {}
    vocab: _Vocab = bundle["vocab"]
    x = _mono(audio)

    # params latin_only: nur lateinische Zeichen ausgeben (Tagalog, Englisch, Cebuano …)
    keep = _latin_mask(bundle) if params.get("latin_only") else None

    def reduce(lp: Any) -> np.ndarray:
        if keep is not None:
            lp = lp.masked_fill(~keep.to(lp.device)[: lp.shape[-1]], float("-inf"))
        best, idx = lp.max(dim=-1)
        return torch.stack([idx.float(), best, lp[:, BLANK]], dim=1).cpu().numpy()

    r = _run(bundle, x, params, reduce)
    if not len(r):
        return {"text": "", "words": [], "logprob": 0.0}
    ids = r[:, 0].astype(np.int64)
    pmax = np.exp(r[:, 1])
    lp_tok = r[:, 1][ids != BLANK]
    off = float(params.get("offset_seconds") or 0.0)
    how = str(params.get("word_prob") or WORD_PROB)
    words: list[list[Any]] = []
    cur: list[Any] = []  # [erstes Bild, letztes Bild, Zeichen, Wahrscheinlichkeiten je Zeichen]

    def close() -> None:
        if cur and cur[2]:
            words.append([round(off + cur[0] * FRAME_SECONDS, 3), round(off + (cur[1] + 1) * FRAME_SECONDS, 3),
                          "".join(cur[2]), round(_word_prob(cur[3], how), 4)])
        cur.clear()

    pause = int(PAUSE_WORD_SECONDS / FRAME_SECONDS)
    t, T = 0, len(ids)
    while t < T:
        tok = ids[t]
        e = t
        while e + 1 < T and ids[e + 1] == tok:
            e += 1
        if tok != BLANK and tok not in vocab.special:
            if tok == vocab.space:
                close()
            else:
                if cur and t - cur[1] > pause:
                    close()  # an Pausen zwischen Äußerungen gibt das Modell oft kein Leerzeichen aus
                if not cur:
                    cur.extend([t, e, [], []])
                cur[1] = e
                cur[2].append(vocab.pieces[tok])
                cur[3].append(float(pmax[t:e + 1].max()))
        t = e + 1
    close()
    return {"text": " ".join(w[2] for w in words), "words": words,
            "logprob": round(float(lp_tok.mean()), 4) if len(lp_tok) else 0.0}


# ------------------------------------------------------------------------------------------------ Ausrichten

def _labels(word: str, vocab: _Vocab, sym: dict[str, int], digits: str) -> list[int]:
    """Ein Wort des Textes als Spalten: Kleinbuchstaben (Groß- und Kleinschreibung zusammen), Satzzeichen fallen weg,
    Ziffern als Zeichen (digits „keep“) oder ein Platzhalter je Zahl („wildcard“), unbekannte Zeichen und Symbole
    (%, €, …) als Platzhalter; mehrere Platzhalter hintereinander werden einer."""
    out: list[int] = []
    for ch in unicodedata.normalize("NFC", word):
        cat = unicodedata.category(ch)
        spoken = cat[0] == "S" or ch in "%‰&@#"  # Zeichen, die als Wort gesprochen werden („porsyento“)
        if (cat[0] == "P" and not spoken) or cat[0] in "ZC":
            continue
        key = ch.lower() if len(ch.lower()) == 1 else ch
        if spoken or (cat == "Nd" and digits == "wildcard"):
            key = ""
        if key and key not in vocab.fold:
            base = "".join(c for c in unicodedata.normalize("NFD", key) if unicodedata.category(c) != "Mn")
            key = base if len(base) == 1 and base in vocab.fold else ""
        if not key:
            if not out or out[-1] != WILD:
                out.append(WILD)
            continue
        if key not in sym:
            sym[key] = len(sym) + 1  # Spalte 0 ist Blank
        out.append(sym[key])
    return out


def _viterbi(E: np.ndarray, labels: np.ndarray, jumps: list[tuple[int, int, int]] | None = None,
             penalty: float = 0.0, starts: list[tuple[int, float]] | None = None,
             ends: list[tuple[int, float]] | None = None) -> np.ndarray | None:
    """Bester CTC-Pfad. E: (T, A) Log-Wahrscheinlichkeiten, Spalte 0 Blank, labels: (L,) Spalten (WILD = Platzhalter,
    kostet WILD_COST je Bild). jumps: (Ziel, Quelle 1, Quelle 2) zum Überspringen eines Wortes, kostet penalty (nat).
    starts/ends: weitere Anfangs- und Endzustände als (Zustand, Kosten), für das erste und letzte Wort. Gibt je Bild
    den Zustand 0..2L zurück (ungerade = Zeichen (s-1)/2), None wenn der Text nicht in die Bilder passt."""
    T, L = len(E), len(labels)
    if L == 0:
        return np.zeros(T, np.int32)
    S = 2 * L + 1
    need = L + int(np.sum((labels[1:] == labels[:-1]) & (labels[1:] != WILD)))
    if T < need and not jumps:
        return None
    em = np.zeros((T, S), np.float32)
    em[:, 0::2] = E[:, [0]]
    em[:, 1::2] = np.where(labels[None, :] == WILD, -WILD_COST, E[:, np.maximum(labels, 0)])
    skip = np.zeros(S, bool)
    skip[3::2] = (labels[1:] != labels[:-1]) | (labels[1:] == WILD)
    neg = np.float32(-1e30)
    pen = np.float32(penalty)
    dst = np.array([j[0] for j in jumps or []], np.int64)
    src1 = np.array([j[1] for j in jumps or []], np.int64)
    src2 = np.array([j[2] for j in jumps or []], np.int64)
    a = np.full(S, neg, np.float32)
    a[0], a[1] = em[0, 0], em[0, 1]
    for s0, cost in starts or []:
        a[s0] = max(a[s0], em[0, s0] - np.float32(cost))
    bp = np.zeros((T, S), np.int8)
    f1 = np.empty(S, np.float32)
    f2 = np.empty(S, np.float32)
    for t in range(1, T):
        f1[0] = neg
        f1[1:] = a[:-1]
        f2[:2] = neg
        f2[2:] = np.where(skip[2:], a[:-2], neg)
        choice = np.zeros(S, np.int8)
        best = a.copy()
        m = f1 > best
        best[m] = f1[m]
        choice[m] = 1
        m = f2 > best
        best[m] = f2[m]
        choice[m] = 2
        if len(dst):
            j1, j2 = a[src1] - pen, a[src2] - pen
            for jv, code in ((j1, 3), (j2, 4)):
                m = jv > best[dst]
                best[dst[m]] = jv[m]
                choice[dst[m]] = code
        bp[t] = choice
        a = best + em[t]
    score, s = max([(float(a[S - 1]), S - 1), (float(a[S - 2]), S - 2)]
                   + [(float(a[e]) - cost, e) for e, cost in ends or []])
    if score < -1e29:
        return None
    jump_from = {int(d): (int(s1), int(s2)) for d, s1, s2 in zip(dst, src1, src2)}
    path = np.empty(T, np.int32)
    for t in range(T - 1, -1, -1):
        path[t] = s
        c = int(bp[t, s])
        s = jump_from[s][c - 3] if c >= 3 else s - c
    return path


def _align_piece(E: np.ndarray, word_labels: list[list[int]], space: int,
                 skip_penalty: float | None = None) -> list[tuple[int, int, float, list[float]]] | None:
    """Wörter (Spalten je Wort) in einem Abschnitt ausrichten; zwischen den Wörtern steht das Leerzeichen. Mit
    skip_penalty darf ein Wort fehlen (Übersprung kostet so viel): Ein erfundenes Wort nimmt dann den Nachbarn keine
    Bilder weg. Gibt je Wort (erstes Bild, Bild nach dem Ende, Anteil Sprache, Zeichen-Wahrscheinlichkeiten) zurück;
    ohne Bilder (-2, -2, …) = übersprungen, (-1, -1, …) = nichts zum Ausrichten (nur Satzzeichen).

    Verworfen (17.11.): ein billiger Rand vor/hinter dem Text für Ton, den der Text nicht abdeckt. Er war günstiger,
    als die Laute eines verhörten Wortes ins Blank zu drücken, und ließ dafür richtige Nachbarwörter aus („Anim na“
    übersprungen); teurer gemacht wird er nie gewählt. Der Text sollte den Ton also abdecken."""
    seq: list[int] = []
    owner: list[int] = []  # Wort je Zeichen, -1 = Leerzeichen
    spans: list[tuple[int, int, int]] = []  # je Wort mit Zeichen: (Wort, erstes, letztes Zeichen in seq)
    for w, labs in enumerate(word_labels):
        if not labs:
            continue
        if seq:
            seq.append(space)
            owner.append(-1)
        spans.append((w, len(seq), len(seq) + len(labs) - 1))
        seq.extend(labs)
        owner.extend([w] * len(labs))
    out: list[tuple[int, int, float, list[float]]] = [(-1, -1, 0.0, [])] * len(word_labels)
    if not seq:
        return out
    jumps: list[tuple[int, int, int]] = []
    starts: list[tuple[int, float]] = []
    ends: list[tuple[int, float]] = []
    if skip_penalty is not None and len(spans) > 1:
        for k, (_w, first, last) in enumerate(spans):
            after = 2 * (last + 1) + 1   # Leerzeichen hinter dem Wort
            before = 2 * (first - 1) + 1  # Leerzeichen davor
            if k == 0:  # erstes Wort: vom Blank am Anfang direkt ins Leerzeichen dahinter
                jumps.append((after, 0, 0))
                starts.append((after, skip_penalty))
            elif k == len(spans) - 1:  # letztes Wort: im Leerzeichen davor (oder dem Blank danach) enden
                ends.extend([(before, skip_penalty), (before + 1, skip_penalty)])
            else:
                jumps.append((after, before, before + 1))
    # Leerzeichen zwischen Wörtern darf auch auf Blank-Bildern liegen: An Pausen zwischen Äußerungen gibt das Modell
    # meist nur Blank aus
    Es = E.copy()
    Es[:, space] = np.logaddexp(E[:, space], E[:, 0])
    path = _viterbi(Es, np.asarray(seq, np.int64), jumps, float(skip_penalty or 0.0), starts, ends)
    if path is None:
        return None
    for w, _first, _last in spans:
        out[w] = (-2, -2, 0.0, [])
    lab_idx = np.where(path % 2 == 1, (path - 1) // 2, -1)
    p_speech = 1.0 - np.exp(E[:, 0])
    got: dict[int, list[Any]] = {}
    for j in np.unique(lab_idx[lab_idx >= 0]):
        fr = np.nonzero(lab_idx == j)[0]
        w = owner[j]
        if w < 0:
            continue
        col = seq[j]
        p = float(np.exp(E[fr, col]).max()) if col != WILD else None
        sp = got.setdefault(w, [fr[0], fr[-1] + 1, [], []])
        sp[0], sp[1] = min(sp[0], fr[0]), max(sp[1], fr[-1] + 1)
        if p is not None:
            sp[2].append(p)
        else:
            sp[3].append(float(p_speech[fr].mean()))
    for w, (a, b, ps, wild) in got.items():
        out[w] = (int(a), int(b), float(p_speech[a:b].mean()), ps if ps else wild)
    return out


def _anchor_cuts(E: np.ndarray, words: list[list[int]], space_col: int, max_frames: int) -> list[tuple[int, int]]:
    """Schnittstellen (Wortindex, Bild) für lange Aufnahmen: gierig dekodieren (nur die Zeichen des Textes), die
    Wörter per SequenceMatcher dem Text zuordnen und zwischen zwei sicher gefundenen Nachbarwörtern schneiden,
    in Abständen von höchstens max_frames."""
    g = E.argmax(axis=1)
    toks: list[tuple[int, int]] = []
    t = 0
    while t < len(g):
        e = t
        while e + 1 < len(g) and g[e + 1] == g[t]:
            e += 1
        if g[t] != 0:
            toks.append((int(g[t]), t))
        t = e + 1
    gw: list[tuple[str, int, int]] = []  # Wort, erstes, letztes Bild
    cur: list[Any] = []
    pause = int(PAUSE_WORD_SECONDS / FRAME_SECONDS)
    for c, fr in toks + [(space_col, -1)]:
        if c == space_col or (cur and fr - cur[1] > pause):
            if cur:
                gw.append(("".join(chr(0x100 + x) for x in cur[2]), cur[0], cur[1]))
            cur = []
        if c != space_col:
            if not cur:
                cur = [fr, fr, []]
            cur[1] = fr
            cur[2].append(c)
    tw = ["".join(chr(0x100 + x) if x != WILD else "*" for x in labs) for labs in words]
    cands: list[tuple[int, int]] = []
    for i, j, size in SequenceMatcher(None, tw, [w for w, _, _ in gw], autojunk=False).get_matching_blocks():
        for k in range(size - 1):
            end, nxt = gw[j + k][2], gw[j + k + 1][1]
            cands.append((i + k + 1, (end + 1 + nxt) // 2))
    cuts: list[tuple[int, int]] = []
    last_f = 0
    for n, (wi, fr) in enumerate(cands):
        nxt_f = cands[n + 1][1] if n + 1 < len(cands) else len(E)
        if fr - last_f >= max_frames // 4 and nxt_f - last_f > max_frames:
            cuts.append((wi, fr))
            last_f = fr
    return cuts


def align(bundle: dict[str, Any], audio: np.ndarray, text: str, params: dict[str, Any] | None = None) -> list[list[Any]]:
    """Text (etwa von Whisper) am Ton ausrichten: je Wort des Textes (getrennt an Leerraum, Schreibweise wie im Text)
    [start_s, end_s, wort, p]. p ist die Wahrscheinlichkeit des Modells für die Zeichen des Wortes an der gefundenen
    Stelle (wie bei transcribe das schwächste Zeichen): klein, wo der Ton das Wort nicht hergibt (verhört, erfunden).
    Groß- und Kleinschreibung zählt nicht, Satzzeichen fallen weg; Zahlen stehen als Ziffern im Text (params digits
    „keep“, Vorgabe) oder als Platzhalter („wildcard“), Symbole (%, €, …) und unbekannte Zeichen als Platzhalter (p dann
    = Anteil Sprache im Bereich). Ein Wort, das der Ton gar nicht hergibt, darf fehlen (params skip_penalty, Vorgabe
    SKIP_PENALTY; None schaltet ab): Länge 0 und p = 0. Wörter ohne Buchstaben (nur Satzzeichen) bekommen die Länge 0
    und p = 1. Bis MAX_CELLS (Bilder × Zustände) in einem Stück, länger in Abschnitten von ~PIECE_SECONDS zwischen
    sicher wiedergefundenen Wörtern (eine Stunde: ~12 s auf der CPU). Der Text sollte den Ton abdecken (etwa ein
    Whisper-Abschnitt mit höchstens ~0,5 s Rand): Ton ohne Text nimmt sonst ein Platzhalter oder das Blank auf."""
    import torch

    params = params or {}
    vocab: _Vocab = bundle["vocab"]
    raw = text.split()
    if not raw:
        return []
    sym: dict[str, int] = {}
    digits = str(params.get("digits") or "keep")
    wl = [_labels(w, vocab, sym, digits) for w in raw]
    space_col = len(sym) + 1
    # Spalten: 0 Blank (+ Satzzeichen, die im Text gestrichen sind), 1… Zeichen des Textes, zuletzt das Leerzeichen
    member = torch.zeros((vocab.size, space_col + 1), dtype=torch.float32)
    member[[BLANK, *vocab.punct], 0] = 1.0
    for key, col in sym.items():
        member[vocab.fold[key], col] = 1.0
    member[vocab.space, space_col] = 1.0
    x = _mono(audio)
    dev_member: dict[str, Any] = {}

    def reduce(lp: Any) -> np.ndarray:
        mm = dev_member.setdefault("m", member.to(lp.device))
        return torch.log((lp.exp() @ mm).clamp_min(1e-30)).cpu().numpy()

    E = _run(bundle, x, params, reduce)
    off = float(params.get("offset_seconds") or 0.0)
    how = str(params.get("word_prob") or WORD_PROB)
    T = len(E)
    res: list[tuple[int, int, float, list[float]]] = [(-1, -1, 0.0, [])] * len(raw)
    if T:
        n_labels = sum(len(x_) + 1 for x_ in wl)
        max_cells = int(params.get("max_cells") or MAX_CELLS)
        pieces: list[tuple[int, int, int, int]] = []  # Wörter [a, b), Bilder [f0, f1)
        if T * (2 * n_labels + 1) <= max_cells:
            pieces.append((0, len(raw), 0, T))
        else:
            # Abschnitte von etwa PIECE_SECONDS (Aufwand wächst mit Bildern × Zeichen je Abschnitt), höchstens so
            # lang, dass Bilder × Zustände im Rahmen bleiben
            max_frames = int(max(250, min(PIECE_SECONDS / FRAME_SECONDS,
                                          math.sqrt(max_cells / max(1e-6, 2 * n_labels / T)))))
            cuts = _anchor_cuts(E, wl, space_col, max_frames)
            bounds = [(0, 0)] + cuts + [(len(raw), T)]
            for (a, f0), (b, f1) in zip(bounds[:-1], bounds[1:]):
                pieces.append((a, b, f0, f1))
        skip = params.get("skip_penalty", SKIP_PENALTY)
        skip = None if skip is None or float(skip) <= 0 else float(skip)
        for a, b, f0, f1 in pieces:
            got = None
            if (f1 - f0) * (2 * sum(len(x_) + 1 for x_ in wl[a:b]) + 1) <= max_cells * 4:
                got = _align_piece(E[f0:f1], wl[a:b], space_col, skip)
            if got is None:
                # passt nicht (zu wenige Bilder oder zu groß): gleichmäßig nach Zeichenzahl verteilen
                lens = np.array([max(1, len(x_)) for x_ in wl[a:b]], float)
                edges = f0 + np.round(np.concatenate([[0], np.cumsum(lens)]) / lens.sum() * (f1 - f0)).astype(int)
                got = [(int(edges[k]), int(edges[k + 1]), 0.0, [0.0]) for k in range(b - a)]
            else:
                got = [(s + f0, e + f0, ps, pr) if s >= 0 else (s, e, ps, pr) for s, e, ps, pr in got]
            res[a:b] = got
    out: list[list[Any]] = []
    last = 0
    for w, (s, e, _ps, probs) in zip(raw, res):
        if s < 0:
            # Länge 0 hinter dem vorigen Wort: nur Satzzeichen (p = 1), übersprungen oder gar kein Ton (p = 0)
            out.append([round(off + last * FRAME_SECONDS, 3), round(off + last * FRAME_SECONDS, 3), w,
                        1.0 if s == -1 and T else 0.0])
            continue
        out.append([round(off + s * FRAME_SECONDS, 3), round(off + e * FRAME_SECONDS, 3), w,
                    round(_word_prob(probs, how), 4)])
        last = e
    return out
