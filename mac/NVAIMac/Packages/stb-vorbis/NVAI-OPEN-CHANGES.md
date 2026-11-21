# Changes for NVAI-open / Änderungen für NVAI-open

Copy of `stb_vorbis.c` from [nothings/stb](https://github.com/nothings/stb), version 1.25 (commit 033efa1, 2026-11-19),
SHA-256 `97a8febc738e6a29fafc8d8bc557c7f17ad3db7ba6544485f59395cc6008b764`. License: MIT or public domain, at your
choice (text at the end of the file and in `LICENSE`). The file is **unchanged**. NVAI-open adds only `Package.swift`
(a C target with `STB_VORBIS_NO_PULLDATA_API`: push API only, no stdio) and `include/StbVorbis.h`, which includes the
header part of the original file for Swift.

Used by the audio forensics of NVAI-open for Mac to read VDR exports (Furuno VR-7000): every 15 s block holds one Ogg
Vorbis file per channel pair, cut from one continuous encoder, so one decoder runs across all files
(`Sources/Forensic/VDROgg.swift`). The Swift side rewrites the audio pages into one ordinary Ogg stream (page numbers,
summed granule positions, no BOS/EOS flags in between, new CRC). Two points that matter for this version:

- A page with granule position −1 (no packet ends on it) is rejected by the new granule check in 1.25 (`loc >= 1 << 50`
  is tested before `loc != ~0`); the rewritten stream repeats the last position instead.
- On a page with the EOS flag, 1.25 truncates the last packet to the granule position and restarts the overlap, so the
  first packet of the next file would yield nothing; the flag is cleared except at the real end.

Kopie von stb_vorbis 1.25 (Commit 033efa1), unverändert; Lizenz nach Wahl MIT oder Public Domain. Dazu nur
Package.swift (nur Push-API) und include/StbVorbis.h. Genutzt für den Ton der VDR-Exporte in der Ton-Forensik des Macs:
ein Dekoder über alle Blockdateien eines Kanalpaars (`Sources/Forensic/VDROgg.swift`).
