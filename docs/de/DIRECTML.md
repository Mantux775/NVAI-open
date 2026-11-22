# Ältere Radeons: DirectML und Vulkan (experimentell)

[English](../DIRECTML.md)

AMDs PyTorch für Windows (ROCm) kennt die Radeon RX 5000, Vega, Radeon VII und Polaris (RX 400/500) nicht. NVAI-open
rechnet auf diesen Karten auf zwei Wegen: Bilder und Ton über **DirectML**, die Schnittstelle von DirectX 12 für
maschinelles Lernen (seit 0.5.33), und Video über eine zweite Engine, **stable-diffusion.cpp mit Vulkan** (seit 0.5.34).
Beides ist experimentell: Auf so einer Karte lief NVAI-open noch nicht. Alles hier wurde auf einer NVIDIA-Karte gemessen,
deren Speicher auf das begrenzt war, was eine 8-GB-Karte bekommt. Berichte in
[Issue #3](https://github.com/Mantux775/NVAI-open/issues/3) helfen sehr.

## Einrichten

NVAI-open wie gewohnt installieren, auch über eine ältere Fassung. Das Setup erkennt die Karte, legt eine zweite
ComfyUI-Umgebung mit PyTorch 2.4.1 und Microsofts torch-directml an (rund 200 MB Download), lädt stable-diffusion.cpp
für Vulkan (28 MB) und prüft beides auf der Karte. Oben in der Leiste steht dann „DirectML (experimentell)“; mit der Maus
darüber steht, was das bedeutet.

![Die Leiste oben mit „DirectML (experimentell)“ und der Erklärung](../images/directml-bar-de.jpg)

Rechnet DirectML auf der Karte nicht oder startet ComfyUI damit nicht, rechnet NVAI-open Bilder und Ton wie bisher auf
dem Prozessor. Oben steht dann „Rechnet auf dem Prozessor“, und der Tooltip nennt den Grund. Sieht Vulkan die Karte
nicht, gibt es kein Video. „NVAI-open reparieren“ im Startmenü richtet alles neu ein.

## Welche Modelle

Unter „Modelle“ sind die Modelle, die zur Karte passen, als empfohlen markiert, und jedes andere sagt, warum nicht.

- **Empfohlen:** die SDXL-Modelle (Juggernaut XL v9, SDXL base, Pony V6 XL, Illustrious XL, NoobAI XL) für Bilder,
  Stable Audio Open für Geräusche und Wan 2.1 T2V 1.3B für Video über Vulkan, als langsam markiert (3 Sekunden in
  832 × 480 dauerten auf der Vergleichskarte 4,5 bis 5,5 Minuten). Neue Videoszenen im Studio nehmen es von selbst, und
  unter jeder Modellwahl in „Generieren“ und im Studio steht, was das Modell auf dieser Karte tut.
- **Langsam:** Stable Audio 3 Medium für Musik, das beim Dekodieren kurz bis zu 10 GB braucht.
- **Noch nicht:** andere Videomodelle und die großen Modelle wie Qwen-Image, FLUX 3, Krea 2, MOSS-Image oder LTX-2.5: zu
  groß für 8 GB oder auf NVIDIA- bzw. ROCm-Kerne angewiesen (NVFP4, INT8, FP8). Sprecherstimme und 3D brauchen CUDA oder
  ROCm. Audio-Werkzeuge und Ton-Forensik rechnen auf dem Prozessor.

![Modellseite: Juggernaut XL empfohlen, Qwen-Image nicht für diese Karte, Stable Audio 3 als langsam markiert](../images/directml-models-de.jpg)

## Video über Vulkan

Microsofts DirectML-Erweiterung für PyTorch verarbeitet nur Tensoren mit höchstens fünf Dimensionen, und Videomodelle
brauchen an einigen Stellen mehr: Wan 2.1 setzt seine Bilder in acht zusammen, über DirectML brach es nach zwei
Schritten zu je 27 s ab. stable-diffusion.cpp rechnet ohne PyTorch direkt über Vulkan, das Radeons, Intel-Karten und
NVIDIA-Karten gleichermaßen sprechen. Es nimmt dieselben Modelldateien wie ComfyUI (Wan 2.1 T2V 1.3B mit Text-Encoder
und VAE), hält Text-Encoder und VAE im Arbeitsspeicher und das Videomodell auf der Karte. Vor einem Video schließt
NVAI-open das DirectML-ComfyUI, damit dessen Speicher frei wird; das nächste Bild oder der nächste Ton startet es wieder
(rund 30 s).

![Somi fährt mit dem Rasenmäher durch ein Feld verängstigter Gesichter, schwarze Tusche mit blauen Ohren](../images/vulkan-somi.gif)

<sub>Somi, der Hase aus unserem Kurzfilm, mäht ein Feld verängstigter Gesichter: Wan 2.1 1.3B über Vulkan, 3 s in
832 × 480 in 5,5 Minuten auf der Vergleichskarte. Ohne LoRA zeichnet Wan ihn nur nach der Beschreibung, hier schwarz
statt weiß.</sub>

## Gemessen: CUDA, DirectML und Vulkan auf derselben Karte

Dieselben Aufträge mit denselben Seeds auf einer RTX 5060 Ti 16 GB: mit CUDA, über DirectML und über Vulkan, die
beiden letzten auf den Speicher begrenzt, den Windows einer 8-GB-Karte gibt (7,7 GB). Zeiten je Auftrag, samt Laden
des Modells.

| Auftrag | CUDA | DirectML | Vulkan |
|---|---|---|---|
| SDXL (Juggernaut XL v9), 1024 × 1024, 28 Schritte | 16 s | 83 s | 34 s¹ |
| SDXL, 832 × 1216, 28 Schritte | 13 s | 81 s | – |
| Stable Audio Open, 6 s Geräusch | 8 s | 17 s | – |
| Stable Audio 3 Medium, 30 s Musik | 6 s | 16 s | – |
| Wan 2.1 T2V 1.3B, 832 × 480, 33 Bilder (2 s), 30 Schritte | 117 s | Abbruch nach 2 Schritten | 194 s |

<sub>¹ Mit stable-diffusion.cpp direkt gemessen; Bilder rechnet NVAI-open vorerst über DirectML.</sub>

Auf derselben Karte war DirectML 2- bis 6-mal langsamer als CUDA, Vulkan bei Video 1,7-mal langsamer und bei Bildern
etwa doppelt so schnell wie DirectML. Auf der NVIDIA-Karte nutzten beide ihre Matrix-Einheiten; eine ältere Radeon hat
keine, ihre Zeiten liegen also höher, wie viel, ist noch nicht gemessen.

![Somi über DirectML: ein Bankett für einen mit einer einzigen Platte Karotten, und Somi im Kapuzenmantel im Sonnenblumenfeld](../images/directml-somi.jpg)

<sub>Somi über DirectML mit Juggernaut XL: ein Bankett für einen und ein Gang im Kapuzenmantel durchs Sonnenblumenfeld.
Ohne LoRA für SDXL ist er nur nach der Beschreibung gezeichnet.</sub>

## Wie es funktioniert

- torch-directml gibt es nur für PyTorch 2.4.1, und ComfyUI hat DirectML in Fassung 0.46.0 entfernt. NVAI-open hält
  deshalb eine zweite Umgebung für das Bild-ComfyUI (`external\comfyui\.venv-directml`) und setzt DirectML vor jedem
  Start wieder in ComfyUI ein; ohne DirectML ändert sich nichts.
- ComfyUIs alter DirectML-Code nahm 1 GB Speicher an und hielt alle Modelle zugleich (SDXL belegte 13,6 GB). NVAI-open
  fragt stattdessen Windows nach dem Speicherbudget des Prozesses: Modelle werden wie mit CUDA gewechselt, und das VAE
  dekodiert kachelweise, wenn es sonst nicht passt.
- DirectML reiht Arbeit weit voraus ein und hält den Speicher jedes eingereihten Schritts, bis er gelaufen ist; ohne
  regelmäßigen Abgleich schwankte SDXL zwischen 6 und 15 GB. Mit Abgleich belegte es höchstens 8,5 GB und ist schneller.
- Text-Encoder rechnen auf dem Prozessor (DirectML kann keine FP8-Gewichte), 3D-Faltungen werden als 2D-Faltungen
  gerechnet.
- Jedes Video ist ein Lauf von stable-diffusion.cpp (`external\sdcpp\sd-cli.exe`); sein Protokoll steht in `sdcpp.log`
  im Datenordner, und „Problem melden“ hängt es an.
- Die Umgebungsvariable `NVAI_DIRECTML=0` schaltet DirectML ab, `NVAI_SDCPP_ENGINE=0` die Vulkan-Engine.
