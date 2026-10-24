import Foundation

// `--selftest` prüft Einstellungen, PhotoCraft und NVAI-open ohne Fenster – etwa per ssh:
//   "NVAI-open for PhotoCraft.app/Contents/MacOS/NVAIPhotoCraft" --selftest
if CommandLine.arguments.contains("--selftest") {
    Task.detached {
        let ok = await SelfTest.run()
        exit(ok ? 0 : 1)
    }
    dispatchMain()
}

// Menüs, die macOS selbst beisteuert (Über, Ausblenden, Beenden …), folgen AppleLanguages: bei
// „auto“ der Systemsprache, sonst der gewählten Sprache – wirksam ab diesem Start der App.
let appLanguage = AppSettings.load().language
if appLanguage == "en" || appLanguage == "de" {
    UserDefaults.standard.set([appLanguage], forKey: "AppleLanguages")
} else {
    UserDefaults.standard.removeObject(forKey: "AppleLanguages")
}

NVAIPhotoCraftApp.main()
