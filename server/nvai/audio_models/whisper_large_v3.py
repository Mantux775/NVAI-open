"""Whisper large-v3 (OpenAI, MIT) für die Übersetzer-Spur der Ton-Forensik, über transformers aus dem venv von
ComfyUI (kein faster-whisper: CTranslate2 braucht CUDA-12-Bibliotheken, Recherche 17.11.2026).

Gegen erfundene Sätze (Whisper „hört“ auf Stille und Lärm Text): Es bekommt nur Abschnitte, in denen Sprache gefunden
wurde, jeder Abschnitt einzeln (kein Vorlauf aus dem vorigen), dazu je Abschnitt die Wahrscheinlichkeit für „keine
Sprache“, die mittlere Token-Wahrscheinlichkeit und die Wiederholungsrate (zlib) als Prüfwerte.
"""
from __future__ import annotations

import math
import zlib
from typing import Any

import numpy as np

SAMPLE_RATE = 16000
CHANNELS = 1
STEMS: list[str] = []
MAX_SECONDS = 29.5


def load(weights_dir, device, params):
    import torch
    from transformers import WhisperForConditionalGeneration, WhisperProcessor
    dtype = torch.float16 if device == "cuda" else torch.float32
    proc = WhisperProcessor.from_pretrained(str(weights_dir))
    model = WhisperForConditionalGeneration.from_pretrained(str(weights_dir), dtype=dtype, attn_implementation="sdpa")
    model = model.to(device).eval()
    tok = proc.tokenizer
    lang_ids = {}
    for code in tok.additional_special_tokens if hasattr(tok, "additional_special_tokens") else []:
        if len(code) <= 10 and code.startswith("<|") and code.endswith("|>") and code[2:-2].isalpha() and code[2:-2].islower():
            lang_ids[code[2:-2]] = tok.convert_tokens_to_ids(code)
    if not lang_ids:
        from transformers.models.whisper.tokenization_whisper import LANGUAGES
        lang_ids = {c: tok.convert_tokens_to_ids(f"<|{c}|>") for c in LANGUAGES}
    return {"model": model, "proc": proc, "device": device, "dtype": dtype, "lang_ids": lang_ids,
            "sot": tok.convert_tokens_to_ids("<|startoftranscript|>"),
            "nospeech": tok.convert_tokens_to_ids("<|nospeech|>")}


def _probe(bundle: dict[str, Any], feats) -> tuple[list[str], list[float], list[dict[str, float]]]:
    """Ein Decoder-Schritt nach <|startoftranscript|>: Sprache und Wahrscheinlichkeit für „keine Sprache“."""
    import torch
    model = bundle["model"]
    ids = torch.full((feats.shape[0], 1), bundle["sot"], dtype=torch.long, device=feats.device)
    with torch.inference_mode():
        logits = model(input_features=feats, decoder_input_ids=ids).logits[:, -1].float()
    probs = torch.softmax(logits, dim=-1)
    nos = probs[:, bundle["nospeech"]].tolist()
    codes = list(bundle["lang_ids"].keys())
    idx = torch.tensor([bundle["lang_ids"][c] for c in codes], device=logits.device)
    lp = torch.softmax(logits[:, idx], dim=-1)
    langs, tops = [], []
    for row in lp:
        order = torch.argsort(row, descending=True)[:3].tolist()
        langs.append(codes[order[0]])
        tops.append({codes[i]: round(float(row[i]), 3) for i in order})
    return langs, nos, tops


def transcribe(bundle: dict[str, Any], clips: list[np.ndarray], params: dict[str, Any]) -> list[dict[str, Any]]:
    """clips: Mono-Abschnitte mit 16 kHz, je höchstens 30 s. params: language ("tl", "en" … oder "auto"),
    allowed (Sprachen, auf die „auto“ beschränkt wird), beams. Ergebnis je Abschnitt: text, lang, lang_probs,
    no_speech, logprob (mittel je Token), compression, words [[Anfang, Ende, Wort, Wahrscheinlichkeit] …]."""
    import torch
    model, proc = bundle["model"], bundle["proc"]
    tok = proc.tokenizer
    feats = proc.feature_extractor([c.astype(np.float32) for c in clips], sampling_rate=SAMPLE_RATE, return_tensors="pt")
    x = feats.input_features.to(bundle["device"], bundle["dtype"])
    langs, nos, tops = _probe(bundle, x)
    want = (params.get("language") or "auto").lower()
    allowed = [a for a in (params.get("allowed") or []) if a in bundle["lang_ids"]]
    if want != "auto":
        langs = [want] * len(clips)
    elif allowed:
        # „auto“ nur zwischen den erwarteten Sprachen (z. B. Tagalog und Englisch): sonst rät Whisper bei Lärm Exotisches
        langs = [max(allowed, key=lambda c: tp.get(c, 0.0)) if lg not in allowed else lg for lg, tp in zip(langs, tops)]
    out: list[dict[str, Any]] = [{} for _ in clips]
    # Gierig und mit Längengrenze (Messung 17.11.: Beam-Suche verstärkte Wiederholungsschleifen auf Lärm, je
    # Abschnitt höchstens rund 8 Token je Sekunde); keine Whisper-Wortzeiten (langsam), die kommen aus der Ausrichtung
    secs = [len(c) / SAMPLE_RATE for c in clips]
    for lang in sorted(set(langs)):
        idx = [i for i, lg in enumerate(langs) if lg == lang]
        sub = x[idx]
        limit = int(min(220, max(16, 8 * max(secs[i] for i in idx) + 12)))
        with torch.inference_mode():
            gen = model.generate(input_features=sub, language=lang, task="transcribe", num_beams=1, do_sample=False,
                                 return_dict_in_generate=True, output_scores=True, max_new_tokens=limit)
        seqs = gen["sequences"] if isinstance(gen, dict) else gen.sequences
        scores = gen["scores"] if isinstance(gen, dict) else gen.scores
        try:
            trans = model.compute_transition_scores(seqs, scores, normalize_logits=True).float().cpu().numpy()
        except Exception:  # noqa: BLE001 - ohne Einzelwerte bleibt nur der Text
            trans = None
        special = set(tok.all_special_ids)
        for k, i in enumerate(idx):
            row = seqs[k].tolist()
            n_gen = trans.shape[1] if trans is not None else 0
            gen_tokens = row[len(row) - n_gen:] if n_gen else []
            logp = trans[k] if trans is not None else np.zeros(0)
            words: list[list[Any]] = []
            cur: list[Any] | None = None
            vals = []
            hit_limit = len([tq for tq in gen_tokens if tq not in special]) >= limit - 4
            for j, tid in enumerate(gen_tokens):
                lpv = float(logp[j]) if j < len(logp) else 0.0
                if tid in special or not np.isfinite(lpv):
                    continue
                vals.append(lpv)
                text = tok.convert_tokens_to_string([tok.convert_ids_to_tokens(tid)])
                if cur is None or text.startswith(" "):
                    if cur is not None:
                        words.append(cur)
                    cur = [None, None, text.strip(), math.exp(lpv)]
                else:
                    cur[2] += text
                    cur[3] = min(cur[3], math.exp(lpv))
            if cur is not None:
                words.append(cur)
            text = tok.decode(row, skip_special_tokens=True).strip()
            comp = len(text.encode()) / max(1, len(zlib.compress(text.encode()))) if text else 0.0
            out[i] = {"text": text, "lang": lang, "lang_probs": tops[i], "no_speech": round(float(nos[i]), 3),
                      "logprob": round(float(np.mean(vals)), 3) if vals else None, "compression": round(comp, 2),
                      "hit_limit": hit_limit, "words": [[None, None, w[2], round(w[3], 3)] for w in words if w[2]]}
    return out
