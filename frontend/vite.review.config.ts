import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// Prüf-App (NVAI-Pruefer.html): eigener Einstieg review.html, alles in einer Datei (scripts/inline-review.mjs bettet
// JS und CSS danach in die Seite ein), läuft von der Platte (file://) ohne Server und ohne Netz.
export default defineConfig({
  plugins: [react()],
  base: './',
  build: {
    outDir: 'dist-review',
    emptyOutDir: true,
    assetsInlineLimit: 100_000_000,
    cssCodeSplit: false,
    modulePreload: false,
    rollupOptions: {
      input: 'review.html',
      output: { inlineDynamicImports: true },
    },
  },
})
