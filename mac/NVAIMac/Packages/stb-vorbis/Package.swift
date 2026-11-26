// swift-tools-version: 5.9
//
// stb-vorbis — der Ogg-Vorbis-Dekoder stb_vorbis von Sean Barrett (MIT oder Public Domain, nach Wahl) als
// C-Bibliothek für NVAI-open für Mac: Ton der VDR-Exporte (Ship Blackbox) fortlaufend über alle Blockdateien
// dekodieren (Push-API). Die Datei Sources/StbVorbis/stb_vorbis.c ist unverändert, siehe NVAI-OPEN-CHANGES.md.
import PackageDescription

let package = Package(
    name: "StbVorbis",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StbVorbis", targets: ["StbVorbis"]),
    ],
    targets: [
        .target(
            name: "StbVorbis",
            path: "Sources/StbVorbis",
            cSettings: [
                // nur die Push-API (keine Dateien, kein stdio); muss zu include/StbVorbis.h passen
                .define("STB_VORBIS_NO_PULLDATA_API"),
            ]
        ),
    ]
)
