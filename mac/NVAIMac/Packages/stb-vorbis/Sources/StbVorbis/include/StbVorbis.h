// Öffentliche Schnittstelle von stb_vorbis für Swift (`import StbVorbis`): nur der Kopfteil der unveränderten
// Originaldatei ../stb_vorbis.c, ohne Pull-API und ohne stdio (NVAI-open nutzt nur die Push-API, siehe
// NVAI-OPEN-CHANGES.md). Dieselben Schalter setzt Package.swift für das Übersetzen der Implementierung.
#ifndef NVAI_STB_VORBIS_H
#define NVAI_STB_VORBIS_H

#ifndef STB_VORBIS_NO_PULLDATA_API
#define STB_VORBIS_NO_PULLDATA_API
#endif

#define STB_VORBIS_HEADER_ONLY
#include "../stb_vorbis.c"
#undef STB_VORBIS_HEADER_ONLY

#endif
