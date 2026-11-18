// Prüf-App (NVAI-Pruefer.html): eigenständig, ohne Server, ohne KI, ohne Internet (Nutzer 18.11.2026: „eine
// eigenständige App die komplett standalone funktioniert, ohne downloads. und dort will ich das projekt importieren zum
// weiterbearbeiten, dann halt ohne KI. aber mit allen übersetzungen“). review.html setzt window.__NVAI_REVIEW__, bevor
// die Arbeitsfläche lädt; sie blendet dann aus, was einen Server braucht (KI, Rechnen, Exporte über den Server, Löschen,
// Videoabgleich).

export function isReview(): boolean {
  return typeof window !== 'undefined' && !!(window as unknown as { __NVAI_REVIEW__?: boolean }).__NVAI_REVIEW__
}
