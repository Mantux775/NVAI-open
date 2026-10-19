// Kopiert aus ios/NVAILocal (unverändert), für NV-AI für Mac.
import Foundation

/// Liest das Inhaltsverzeichnis eines ZIP-Archivs auf dem Server, ohne es zu laden.
///
/// Ein ZIP traegt sein Verzeichnis am Ende. Zwei, drei kleine Range-Anfragen
/// genuegen deshalb, um bei einem 6-GB-Paket zu sehen, ob alle Teile einer
/// Pipeline drinstecken -- bevor jemand eine Stunde auf einen Download wartet,
/// den die App dann nicht ausfuehren kann.
enum ZipInhalt {

    struct Fehler: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    /// Alle Pfade im Archiv, so wie sie beim Entpacken entstehen.
    static func namen(von url: URL) async throws -> [String] {
        // HuggingFace leitet auf ein CDN um. Erst die endgueltige Adresse und
        // die Groesse holen, dann alle Bereiche direkt dort anfragen -- ob ein
        // Range-Kopf eine Umleitung uebersteht, ist nicht garantiert.
        var kopf = URLRequest(url: url)
        kopf.httpMethod = "HEAD"
        let (_, antwort) = try await URLSession.shared.data(for: kopf)
        guard let http = antwort as? HTTPURLResponse, http.statusCode == 200,
              let ziel = http.url else { throw Fehler(text: t("Archiv nicht erreichbar.", "Archive not reachable.")) }
        let groesse = http.expectedContentLength
        guard groesse > 22 else { throw Fehler(text: t("Größe des Archivs unbekannt.", "Archive size unknown.")) }

        // Das Ende enthaelt den End-of-Central-Directory-Satz (22 Byte plus
        // hoechstens 64 KB Kommentar) und bei ZIP64 den Locator davor.
        let schwanzLaenge = min(groesse, 65_557 + 20 + 56)
        let schwanzStart = groesse - schwanzLaenge
        let schwanz = try await bereich(ziel, von: schwanzStart, laenge: schwanzLaenge)

        guard let eocd = sucheRueckwaerts(schwanz, signatur: 0x0605_4b50) else {
            throw Fehler(text: t("Kein gültiges ZIP-Archiv.", "Not a valid ZIP archive."))
        }
        var cdGroesse = Int64(u32(schwanz, eocd + 12))
        var cdStart = Int64(u32(schwanz, eocd + 16))

        // ZIP64 (alles ueber 4 GB): die kurzen Felder stehen auf 0xFFFFFFFF,
        // die echten Werte im ZIP64-Satz, auf den der Locator zeigt.
        if cdGroesse == 0xFFFF_FFFF || cdStart == 0xFFFF_FFFF {
            let locator = eocd - 20
            guard locator >= 0, u32(schwanz, locator) == 0x0706_4b50 else {
                throw Fehler(text: t("ZIP64-Verzeichnis nicht gefunden.", "ZIP64 directory not found."))
            }
            let satzStart = Int64(u64(schwanz, locator + 8))
            let satz: [UInt8]
            if satzStart >= schwanzStart, satzStart + 56 <= groesse {
                let a = Int(satzStart - schwanzStart)
                satz = Array(schwanz[a ..< a + 56])
            } else {
                satz = try await bereich(ziel, von: satzStart, laenge: 56)
            }
            guard satz.count >= 56, u32(satz, 0) == 0x0606_4b50 else {
                throw Fehler(text: t("ZIP64-Verzeichnis beschädigt.", "ZIP64 directory damaged."))
            }
            cdGroesse = Int64(u64(satz, 40))
            cdStart = Int64(u64(satz, 48))
        }
        // Ein Verzeichnis von mehr als 16 MB hat kein Modellpaket -- dann ist
        // eher der Satz falsch gelesen, und so viel soll nicht geladen werden.
        guard cdGroesse > 0, cdGroesse < 16 << 20, cdStart + cdGroesse <= groesse else {
            throw Fehler(text: t("Inhaltsverzeichnis unplausibel.", "Implausible archive directory."))
        }

        let cd: [UInt8]
        if cdStart >= schwanzStart {
            let a = Int(cdStart - schwanzStart)
            cd = Array(schwanz[a ..< a + Int(cdGroesse)])
        } else {
            cd = try await bereich(ziel, von: cdStart, laenge: cdGroesse)
        }

        var namen: [String] = []
        var i = 0
        while i + 46 <= cd.count, u32(cd, i) == 0x0201_4b50 {
            let n = Int(u16(cd, i + 28)), e = Int(u16(cd, i + 30)), k = Int(u16(cd, i + 32))
            guard i + 46 + n <= cd.count else { break }
            namen.append(String(decoding: cd[i + 46 ..< i + 46 + n], as: UTF8.self))
            i += 46 + n + e + k
        }
        guard !namen.isEmpty else { throw Fehler(text: t("Archiv ist leer.", "The archive is empty.")) }
        return namen
    }

    /// Holt einen Byte-Bereich. Ignoriert der Server den Range-Kopf, wird sofort
    /// abgebrochen -- sonst kaeme das ganze Archiv in den Speicher.
    private static func bereich(_ url: URL, von: Int64, laenge: Int64) async throws -> [UInt8] {
        var anfrage = URLRequest(url: url)
        anfrage.setValue("bytes=\(von)-\(von + laenge - 1)", forHTTPHeaderField: "Range")
        let (strom, antwort) = try await URLSession.shared.bytes(for: anfrage)
        guard (antwort as? HTTPURLResponse)?.statusCode == 206 else {
            strom.task.cancel()
            throw Fehler(text: t("Der Server liefert keine Teilbereiche.", "The server does not support range requests."))
        }
        var daten = [UInt8]()
        daten.reserveCapacity(Int(laenge))
        for try await b in strom { daten.append(b) }
        return daten
    }

    private static func sucheRueckwaerts(_ d: [UInt8], signatur: UInt32) -> Int? {
        var i = d.count - 22
        while i >= 0 {
            if u32(d, i) == signatur { return i }
            i -= 1
        }
        return nil
    }

    private static func u16(_ d: [UInt8], _ i: Int) -> UInt16 {
        UInt16(d[i]) | UInt16(d[i + 1]) << 8
    }
    private static func u32(_ d: [UInt8], _ i: Int) -> UInt32 {
        UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
    }
    private static func u64(_ d: [UInt8], _ i: Int) -> UInt64 {
        UInt64(u32(d, i)) | UInt64(u32(d, i + 4)) << 32
    }
}
