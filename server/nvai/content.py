"""Zensiert oder unzensiert? Einstufung der Bild- und Videomodelle im Katalog.

  uncensored  Hersteller oder Modellkarte sagen ausdruecklich: ohne Inhaltsfilter trainiert,
              bzw. ein Feintuning, das genau dafuer gemacht ist.
  partial     Trainingsdaten teilweise gefiltert, das Modell erzeugt nach Herstellerangaben
              oder vielfach belegt trotzdem Nacktheit.
  censored    Trainingsdaten fuer NSFW gefiltert oder Sicherheitsfilter laut Hersteller;
              Nacktheit und explizite Inhalte werden unterdrueckt.
  (fehlt)     unbekannt -- lieber keine Angabe als eine geratene.

Jeder Eintrag nennt seinen Beleg (deutsch, englisch) und die Quelle. Neue Modelle nur mit
Beleg eintragen; im Zweifel weglassen, dann zeigt die Oberflaeche "unbekannt".
"""
from __future__ import annotations

from typing import Any

from .i18n import t

LEVELS = ("uncensored", "partial", "censored")

_BFL = ("Black Forest Labs filtert laut seinen Modellkarten (FLUX.1 Kontext, FLUX.2) die Trainingsdaten auf "
        "NSFW; für dieses Modell selbst steht es nicht ausdrücklich da.",
        "Black Forest Labs filters training data for NSFW according to its model cards (FLUX.1 Kontext, "
        "FLUX.2); this model's own card does not say so explicitly.",
        "https://huggingface.co/black-forest-labs/FLUX.2-klein-4B")
_CHROMA = ("Laut Hersteller ohne Sicherheitsfilter trainiert („fully uncensored“), kann explizite Inhalte erzeugen.",
           "Trained without a safety filter according to the maker (\"fully uncensored\"); can generate explicit "
           "content.",
           "https://huggingface.co/lodestones/Chroma1-HD")
_QWEN = ("Der technische Bericht zu Qwen-Image nennt einen NSFW-Filter in der Datenaufbereitung; für 2512 gibt es "
         "keine eigene Angabe, es ist dieselbe Modelllinie.",
         "The Qwen-Image technical report lists an NSFW filter in data preparation; there is no separate "
         "statement for 2512, which is the same model line.",
         "https://arxiv.org/pdf/2508.02324")
_KREA2 = ("Laut Modellkarte wurden die Trainingsdaten vor dem Training auf schädliche Inhalte gefiltert und das "
          "Modell gezielt gegen sexuell explizite Inhalte nachtrainiert.",
          "According to the model card, training data was filtered for harmful content before training and the "
          "model was fine-tuned against sexually explicit content.",
          "https://huggingface.co/krea/Krea-2-Turbo")
_ZIMAGE = ("Die Datenaufbereitung vergibt NSFW-Werte (ohne genannte Schwelle); das Modell erzeugt laut vielen "
           "Berichten trotzdem Nacktheit.",
           "Data preparation assigns NSFW scores (no threshold given); according to many reports the model still "
           "produces nudity.",
           "https://arxiv.org/html/2511.22699")
_WAN = ("Der Wan-Bericht nennt eine Filterung nach NSFW-Werten in allen Trainingsdaten; teilweise Nacktheit kommt "
        "laut Nutzerberichten trotzdem durch.",
        "The Wan report describes filtering by NSFW scores in all training data; according to user reports some "
        "nudity still comes through.",
        "https://arxiv.org/html/2503.20314")

# id -> (Einstufung, Beleg deutsch, Beleg englisch, Quelle). Stand der Recherche: 2026-10-21.
CONTENT: dict[str, tuple[str, str, str, str]] = {
    "sdxl-base": ("partial",
                  "Stability nutzt nach eigener Aussage eine gefilterte Teilmenge von LAION-5B; schwache Nacktheit "
                  "ist möglich.",
                  "Stability says it uses a filtered subset of LAION-5B; weak nudity is possible.",
                  "https://decrypt.co/210461/stability-ai-stable-diffusion-laion-csam"),
    "illustrious-xl": ("uncensored",
                       "Auf dem vollständigen Danbooru-2023-Datensatz trainiert; eine eigene, „minimal "
                       "abgesicherte“ Variante gibt es getrennt.",
                       "Trained on the full Danbooru 2023 dataset; a separate \"minimally safety controlled\" "
                       "variant exists.",
                       "https://huggingface.co/OnomaAIResearch/Illustrious-xl-early-release-v0"),
    "noobai-xl-v1.1": ("uncensored",
                       "Auf den vollständigen Danbooru- und e621-Datensätzen trainiert; das Repo ist als "
                       "„Not-For-All-Audiences“ markiert.",
                       "Trained on the full Danbooru and e621 datasets; the repo is labelled "
                       "\"Not-For-All-Audiences\".",
                       "https://huggingface.co/Laxhar/noobai-XL-1.1"),
    "pony-v6-xl": ("uncensored",
                   "Trainingsdaten etwa zu gleichen Teilen sicher, fragwürdig und explizit; entfernt wurden nur "
                   "explizite Inhalte mit Minderjährigen.",
                   "Training data roughly equal parts safe, questionable and explicit; only explicit content "
                   "involving minors was removed.",
                   "https://civitai.com/models/257749/pony-diffusion-v6-xl"),
    "chroma1-hd-fp8": ("uncensored", *_CHROMA),
    "chroma1-hd": ("uncensored", *_CHROMA),
    "flux1-schnell-fp8": ("censored", *_BFL),
    "flux3-klein-nvfp4": ("censored", *_BFL),
    "flux3-klein-int8": ("censored", *_BFL),
    "flux3-klein-base-nvfp4": ("censored", *_BFL),
    "qwen-image-2512-nvfp4": ("censored", *_QWEN),
    "qwen-image-2512-lightning": ("censored", *_QWEN),
    "qwen-image-2512-int8": ("censored", *_QWEN),
    "krea2-turbo-nvfp4": ("censored", *_KREA2),
    "krea2-turbo-int8": ("censored", *_KREA2),
    "z-image": ("partial", *_ZIMAGE),
    "z-image-int8": ("partial", *_ZIMAGE),
    "wan21-t2v-1.3b": ("partial", *_WAN),
    "wan21-i2v-480p-14b": ("partial", *_WAN),
    "wan22-ti2v-5b": ("partial", *_WAN),
    "wan22-i2v-a14b": ("partial", *_WAN),
    "mochi-1-preview-fp8": ("censored",
                            "Laut Modellkarte wurden Schritte unternommen, um NSFW-Inhalte zu begrenzen.",
                            "According to the model card, steps have been taken to limit NSFW content.",
                            "https://huggingface.co/genmo/mochi-1-preview"),
    # Ohne verlaessliche Angabe (bewusst nicht eingetragen): Juggernaut XL v9, Qwen-Image 2.1,
    # LongCat-Image, LTX-Video 0.9.5, LTX-2.3, Kandinsky 5.0 Video Lite.
}


def lookup(model_id: str) -> dict[str, Any]:
    """Felder fuer ModelInfo: content, content_note, content_source."""
    entry = CONTENT.get(model_id)
    if not entry:
        return {"content": None, "content_note": "", "content_source": ""}
    level, de, en, source = entry
    return {"content": level, "content_note": t(de, en), "content_source": source}
