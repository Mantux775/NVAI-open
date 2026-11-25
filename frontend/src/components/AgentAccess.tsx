import { useEffect, useState } from 'react'
import { api, type McpInfo } from '../api'
import { t } from '../i18n'

/**
 * „KI-Agenten (MCP)“ auf der Modellseite (seit 0.5.39): Claude Code, WorkBuddy, Cursor und andere Agenten nutzen
 * NVAI-open über MCP. Die Adresse /mcp (HTTP) passt für alle, die eine URL nehmen; der Befehl (stdio) für die, die nur
 * Programme starten (Claude Desktop). Zugeklappt wie die Speicherorte.
 */
export function AgentAccess() {
  const [info, setInfo] = useState<McpInfo | null>(null)
  const [open, setOpen] = useState(false)
  const [copied, setCopied] = useState<string | null>(null)

  useEffect(() => {
    api.mcpInfo().then(setInfo).catch(() => setInfo(null))
  }, [])
  if (!info) return null

  const claude = `claude mcp add --scope user --transport http nvai ${info.url}`
  const httpJson = JSON.stringify({ mcpServers: { nvai: { type: 'http', url: info.url } } }, null, 2)
  const stdioJson = JSON.stringify({ mcpServers: { nvai: { command: info.command, args: info.args, env: info.env } } }, null, 2)

  const copy = async (key: string, text: string) => {
    try {
      await navigator.clipboard.writeText(text)
      setCopied(key)
      setTimeout(() => setCopied((c) => (c === key ? null : c)), 1500)
    } catch {
      /* Zwischenablage gesperrt: der Text lässt sich mit einem Klick markieren (user-select: all) */
    }
  }

  const block = (key: string, label: string, text: string) => (
    <div className="agent-block">
      <div className="agent-label">
        <span>{label}</span>
        <button className="btn small ghost" onClick={() => copy(key, text)}>
          {copied === key ? t('Kopiert', 'Copied') : t('Kopieren', 'Copy')}
        </button>
      </div>
      <pre className="agent-code">{text}</pre>
    </div>
  )

  return (
    <section className="panel folder-settings agent-access">
      <button className="folder-head" onClick={() => setOpen(!open)} aria-expanded={open}>
        <span className="folder-title">{t('KI-Agenten (MCP)', 'AI agents (MCP)')}</span>
        <span className="muted small folder-summary">{info.url}</span>
        <span className="muted">{open ? '▴' : '▾'}</span>
      </button>

      {open && (
        <div className="folder-body">
          <p className="hint small">
            {t('Claude Code, WorkBuddy, Cursor und andere KI-Agenten nutzen NVAI-open über MCP: Bild, Video, Ton, 3D und '
              + 'Studio, in derselben Warteschlange wie hier. Die Adresse gilt, solange NVAI-open läuft.',
            'Claude Code, WorkBuddy, Cursor and other AI agents use NVAI-open through MCP: images, video, sound, 3D and '
              + 'the Studio, in the same queue as here. The address works while NVAI-open is running.')}
          </p>
          {block('url', t('Adresse (MCP über HTTP)', 'Address (MCP over HTTP)'), info.url)}
          {block('claude', 'Claude Code', claude)}
          {block('http', t('WorkBuddy, Cursor und andere Agenten mit Adresse (mcp.json)',
            'WorkBuddy, Cursor and other agents with an address (mcp.json)'), httpJson)}
          {block('stdio', t('Agenten, die nur Programme starten (etwa Claude Desktop)',
            'Agents that only start programs (Claude Desktop, for example)'), stdioJson)}
          {info.token && (
            <p className="hint small">
              {t('Von anderen Geräten aus braucht jede Anfrage den Token im Header X-NVAI-Token.',
                'From other devices every request needs the token in the X-NVAI-Token header.')}
            </p>
          )}
        </div>
      )}
    </section>
  )
}
