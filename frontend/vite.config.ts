import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// Im Dev-Modus proxyt Vite alles Server-seitige nach 8100, damit es im Browser
// keine CORS- oder Origin-Sonderfaelle gibt. Im Build liefert FastAPI dist/ selbst aus.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      '/api': { target: 'http://127.0.0.1:8100', changeOrigin: true },
      '/files': { target: 'http://127.0.0.1:8100', changeOrigin: true },
      '/ws': { target: 'ws://127.0.0.1:8100', ws: true },
    },
  },
})
