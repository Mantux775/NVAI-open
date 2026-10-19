import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { App } from './App'
import { getLang } from './i18n'
import './styles.css'

// index.html sagt fest lang="de" -- fuer Browser und Screenreader die gewaehlte Sprache setzen.
document.documentElement.lang = getLang()

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
