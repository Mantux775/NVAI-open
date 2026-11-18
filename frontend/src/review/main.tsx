import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { getLang } from '../i18n'
import '../styles.css'
import { installNativeSave } from './native'
import { ReviewApp } from './ReviewApp'

// Einstieg der Prüf-App (review.html → NVAI-Pruefer.html, eine Datei ohne Nachladen)
document.documentElement.lang = getLang()
// in der Mac-App: „Speichern unter“ über ihren Dialog (WebKit hat kein showSaveFilePicker)
installNativeSave()

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <ReviewApp />
  </StrictMode>,
)
