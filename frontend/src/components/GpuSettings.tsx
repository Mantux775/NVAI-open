import { useEffect, useState } from 'react'
import { api, type GpuInfo, type GpuRole } from '../api'
import { t } from '../i18n'

const ISSUES = 'https://github.com/Mantux775/NVAI-open/issues'

const ROLES: { id: GpuRole; label: string; hint: string }[] = [
  {
    id: 'image', label: t('Bildmodelle', 'Image models'),
    hint: t('FLUX 3, Qwen-Image, Video, Audio', 'FLUX 3, Qwen-Image, video, audio'),
  },
  {
    id: 'text', label: t('Sprachmodelle', 'Language models'),
    hint: t('Prompt-Upsampler, „Prompt ausbauen“', 'prompt upsampler, “Expand prompt”'),
  },
  { id: 'mesh', label: '3D', hint: 'TripoSG, TRELLIS.2' },
]

/**
 * Experimentell seit 0.5: mehrere Grafikkarten und AMD (ROCm). Erscheint nur, wenn es
 * etwas einzustellen oder zu sagen gibt -- mit einer NVIDIA-Karte bleibt die Seite wie bisher.
 */
export function GpuSettings() {
  const [gpus, setGpus] = useState<GpuInfo[]>([])
  const [vendor, setVendor] = useState<'nvidia' | 'amd' | null>(null)
  const [assign, setAssign] = useState<Record<GpuRole, number> | null>(null)
  const [saved, setSaved] = useState<Record<GpuRole, number> | null>(null)
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<string | null>(null)

  useEffect(() => {
    api.gpus().then((r) => {
      setGpus(r.gpus)
      setVendor(r.vendor)
      setAssign(r.assignment)
      setSaved(r.assignment)
    }).catch(() => { /* älterer Server ohne /api/gpus */ })
  }, [])

  const multi = gpus.length > 1
  if (!multi && vendor !== 'amd') return null

  const changed = assign && saved && ROLES.some((r) => assign[r.id] !== saved[r.id])

  const save = async () => {
    if (!assign) return
    setBusy(true)
    setMsg(null)
    try {
      const r = await api.setGpus(assign)
      setSaved(r.assignment)
      setMsg(t('Gespeichert. Die Backends starten beim nächsten Job auf den neuen Karten.',
        'Saved. The backends start on the new cards with the next job.'))
    } catch (e) {
      setMsg(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className="panel gpu-settings">
      <h3>
        {multi ? t('Grafikkarten', 'Graphics cards') : t('AMD-Grafikkarte', 'AMD graphics card')}{' '}
        <span className="badge warn">{t('experimentell', 'experimental')}</span>
      </h3>

      {vendor === 'amd' && (
        <p className="hint small">
          {t(
            'AMD Radeon erkannt. NV-AI rechnet hier mit ROCm. Das ist neu und von uns noch nicht '
              + 'auf AMD getestet: Bildmodelle in INT8 oder FP8 sollten laufen, NVFP4-Modelle sind '
              + 'ein NVIDIA-Format und 3D braucht derzeit NVIDIA. ',
            'AMD Radeon detected. NV-AI uses ROCm here. This is new and not tested on AMD by us yet: '
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
              'Jede Aufgabe bekommt ihre eigene Karte. Liegen die Sprachmodelle auf einer anderen Karte '
                + 'als die Bildmodelle, bleiben beide geladen: „Prompt ausbauen“ muss nichts mehr '
                + 'umladen und läuft parallel zu einem Bild. ',
              'Each task gets its own card. If the language models live on a different card than the '
                + 'image models, both stay loaded: “Expand prompt” no longer has to swap models and runs '
                + 'alongside an image. ',
            )}
            <a href={ISSUES} target="_blank" rel="noreferrer">
              {t('Rückmeldungen gern auf GitHub.', 'Feedback welcome on GitHub.')}
            </a>
          </p>
          <div className="gpu-grid">
            {ROLES.map((r) => (
              <label key={r.id} className="field">
                <span className="label">{r.label} <span className="muted small">({r.hint})</span></span>
                <select
                  value={assign[r.id]}
                  onChange={(e) => setAssign({ ...assign, [r.id]: Number(e.target.value) })}
                >
                  {gpus.map((g) => (
                    <option key={g.index} value={g.index}>
                      {`GPU ${g.index}: ${g.name} (${(g.vram_total_mb / 1024).toFixed(0)} GB)`}
                    </option>
                  ))}
                </select>
              </label>
            ))}
          </div>
          <div className="row-gap">
            <button className="btn small primary" onClick={save} disabled={!changed || busy}>
              {busy ? '…' : t('Übernehmen', 'Apply')}
            </button>
            {msg && <span className="muted small">{msg}</span>}
          </div>
        </>
      )}
    </section>
  )
}
