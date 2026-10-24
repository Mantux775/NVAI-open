import { useEffect, useState } from 'react'
import { api, type GpuInfo, type GpuRole, type UpsamplerFit } from '../api'
import { t } from '../i18n'
import { GPU_ROLES } from './GpuChip'

const ISSUES = 'https://github.com/Mantux775/NVAI-open/issues'
// Messwerte mit zwei Karten (RTX 5060 Ti + RTX 4060), seit 0.5.6 nicht mehr im README
const MEASURED = 'https://github.com/Mantux775/NVAI-open/issues/1#issuecomment-6373776729'

/**
 * Mehrere Grafikkarten und AMD (ROCm). Erscheint nur, wenn es etwas einzustellen oder zu sagen
 * gibt -- mit einer NVIDIA-Karte bleibt die Seite wie bisher. Aufgaben als Zeilen, Karten als
 * Spalten; ein Klick verschiebt die Aufgabe sofort (vorher Ausklapplisten mit „Übernehmen“).
 * Zugeklappt wie „Speicherorte“ (Nutzerwunsch 23.10.2026); die Kopfzeile fasst die Zuordnung
 * zusammen und zeigt ⚠, wenn aufgeklappt eine Warnung stünde.
 */
export function GpuSettings() {
  const [open, setOpen] = useState(false)
  const [gpus, setGpus] = useState<GpuInfo[]>([])
  const [vendor, setVendor] = useState<'nvidia' | 'amd' | null>(null)
  const [assign, setAssign] = useState<Record<GpuRole, number> | null>(null)
  const [auto, setAuto] = useState(false)
  const [upsampler, setUpsampler] = useState<UpsamplerFit | null>(null)
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<string | null>(null)

  const load = () => api.gpus().then((r) => {
    setGpus(r.gpus)
    setVendor(r.vendor)
    setAssign(r.assignment)
    setAuto(Boolean(r.auto))
    setUpsampler(r.upsampler ?? null)
  }).catch(() => { /* älterer Server ohne /api/gpus */ })

  useEffect(() => { load() }, [])

  const multi = gpus.length > 1
  if (!multi && vendor !== 'amd') return null
  const split = assign ? new Set(Object.values(assign)).size > 1 : false

  const apply = async (body: Partial<Record<GpuRole, number>> | { auto: true }) => {
    setBusy(true)
    setMsg(null)
    try {
      await api.setGpus(body)
      await load()
      setMsg(t('Gespeichert. Die Backends starten beim nächsten Auftrag auf der neuen Karte.',
        'Saved. The backends start on the new card with the next job.'))
    } catch (e) {
      setMsg(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  const cardName = (index: number) => {
    const g = gpus.find((c) => c.index === index)
    return g ? `GPU ${index}: ${g.name.replace(/^NVIDIA GeForce /, '')}` : `GPU ${index}`
  }
  const warn = (upsampler != null && !upsampler.fits) || split
  const summary = multi && assign
    ? (split
      ? GPU_ROLES.map((r) => `${r.label}: GPU ${assign[r.id]}`).join(' · ')
      : t(`Alles auf ${cardName(assign.image)}`, `Everything on ${cardName(assign.image)}`))
      + (auto ? t(' · automatisch', ' · automatic') : t(' · eigene Wahl', ' · own choice'))
    : t('AMD Radeon, experimentell', 'AMD Radeon, experimental')

  return (
    <section className="panel gpu-settings folder-settings">
      <button className="folder-head" onClick={() => setOpen(!open)} aria-expanded={open}>
        <span className="folder-title">{multi ? t('Grafikkarten', 'Graphics cards') : t('AMD-Grafikkarte', 'AMD graphics card')}</span>
        <span className="muted small folder-summary">
          {warn && <span className="warn-text">⚠ </span>}
          {summary}
        </span>
        <span className="muted">{open ? '▴' : '▾'}</span>
      </button>

      {open && (
        <div className="folder-body">
          {vendor === 'amd' && (
            <p className="hint small">
              {t(
                'AMD Radeon erkannt. NVAI-open rechnet hier mit ROCm. Das ist neu und von uns noch nicht '
                  + 'auf AMD getestet: Bildmodelle in INT8 oder FP8 sollten laufen, NVFP4-Modelle sind '
                  + 'ein NVIDIA-Format und 3D braucht derzeit NVIDIA. ',
                'AMD Radeon detected. NVAI-open uses ROCm here. This is new and not tested on AMD by us yet: '
                  + 'image models in INT8 or FP8 should run, NVFP4 models are an NVIDIA format and 3D '
                  + 'currently needs NVIDIA. ',
              )}
              <a href={ISSUES} target="_blank" rel="noreferrer">
                {t('Bitte erzähl uns auf GitHub, was geht und was nicht.', 'Please tell us on GitHub what works and what does not.')}
              </a>
            </p>
          )}

          {multi && assign && (
            <>
              <p className="hint small">
                {t(
                  'Ohne eigene Wahl rechnet alles auf der stärksten Karte. Zwei Karten legen ihren Speicher '
                    + 'nicht für ein Modell zusammen, größere Modelle passen dadurch nicht. Gemessen mit '
                    + 'RTX 5060 Ti und RTX 4060: Bilder auf der schwächeren Karte dauerten 3- bis 11-mal so lange, '
                    + 'die Sprachmodelle dort brachten kaum etwas. ',
                  'Without your own choice everything runs on the strongest card. Two cards do not pool their '
                    + 'memory for one model, so they do not make room for larger models. Measured with an '
                    + 'RTX 5060 Ti and an RTX 4060: images on the weaker card took 3 to 11 times as long, and '
                    + 'the language models there brought little. ',
                )}
                <a href={MEASURED} target="_blank" rel="noreferrer">
                  {t('Messwerte und Rückmeldungen in Issue #1 auf GitHub.', 'Measurements and feedback in issue #1 on GitHub.')}
                </a>
              </p>
              <div className="gpu-matrix" style={{ gridTemplateColumns: `minmax(150px, 1.2fr) repeat(${gpus.length}, minmax(120px, 1fr))` }}>
                <span />
                {gpus.map((g) => (
                  <span key={g.index} className="gpu-matrix-head">
                    {`GPU ${g.index}: ${g.name.replace(/^NVIDIA GeForce /, '')}`}
                    <span className="muted small">{`${(g.vram_total_mb / 1024).toFixed(0)} GB`}</span>
                    {g.strongest && <span className="badge ok">{t('stärkste', 'strongest')}</span>}
                  </span>
                ))}
                {GPU_ROLES.map((r) => (
                  <RoleRow key={r.id} role={r} gpus={gpus} current={assign[r.id]} busy={busy}
                    onPick={(index) => apply({ [r.id]: index })} />
                ))}
              </div>
              {upsampler && !upsampler.fits && (
                <p className="hint small warn-text">
                  {t(
                    `Der Prompt-Upsampler (${upsampler.variant}, rund ${upsampler.need_gb.toLocaleString('de-DE')} GB) `
                      + `passt nicht ganz in die ${upsampler.card_gb?.toLocaleString('de-DE')} GB von GPU ${upsampler.card}. `
                      + '„Prompt ausbauen“ dauerte so im Test 134–203 s statt 11 s. Besser die Sprachmodelle auf die '
                      + 'stärkste Karte legen.',
                    `The prompt upsampler (${upsampler.variant}, about ${upsampler.need_gb} GB) does not quite fit into `
                      + `the ${upsampler.card_gb} GB of GPU ${upsampler.card}. “Expand prompt” then took 134–203 s instead `
                      + 'of 11 s in testing. Better put the language models on the strongest card.',
                  )}
                </p>
              )}
              {split && (
                <p className="hint small warn-text">
                  {t(
                    'Mit Aufgaben auf zwei Karten können beide gleichzeitig unter Volllast laufen. Im Test fiel dabei '
                      + 'eine RTX 4060 am Riser-Kabel einmal aus (Windows: „BusReset TDR“), zurück kam sie erst mit '
                      + 'einem Neustart.',
                    'With tasks on two cards, both can run at full load at the same time. In testing, an RTX 4060 on '
                      + 'a riser cable dropped out once (Windows: “BusReset TDR”) and only came back after a restart.',
                  )}
                </p>
              )}
              <div className="gpu-auto">
                {auto ? (
                  <span className="badge ok">{t('Automatisch: stärkste Karte', 'Automatic: strongest card')}</span>
                ) : (
                  <button className="btn small" disabled={busy} onClick={() => apply({ auto: true })}>
                    {t('Automatisch verteilen', 'Distribute automatically')}
                  </button>
                )}
                {msg && <span className="muted small">{msg}</span>}
              </div>
            </>
          )}
        </div>
      )}
    </section>
  )
}

function RoleRow({ role, gpus, current, busy, onPick }: {
  role: { id: GpuRole; label: string; hint: string }
  gpus: GpuInfo[]
  current: number
  busy: boolean
  onPick: (index: number) => void
}) {
  return (
    <>
      <span className="gpu-matrix-role">
        <strong>{role.label}</strong>
        <span className="small">{role.hint}</span>
      </span>
      {gpus.map((g) => {
        const on = current === g.index
        return (
          <button key={g.index} type="button" className={on ? 'gpu-cell on' : 'gpu-cell'}
            disabled={on || busy} aria-pressed={on} onClick={() => onPick(g.index)}
            title={on ? t('läuft auf dieser Karte', 'runs on this card') : t('auf diese Karte legen', 'move to this card')}>
            {on ? `✓ ${t('hier', 'here')}` : t('hierher', 'move here')}
          </button>
        )
      })}
    </>
  )
}
