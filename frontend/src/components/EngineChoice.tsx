// Rechenweg für Bilder und Videos (seit 0.5.35; Nutzer 22.11.2026: „ich soll unter Models Your hardware zwischen cuda
// und vulkan mit stabledifusion.cpp umstellen können … mit dem tip welches ist am besten für welches und auto als auswahl
// in dropdown“, „genau so beim anklicken auf die ram anzeige (wie beim multigpu)“, „bei nicht kompaktiblen gpus gibt es
// dann nur kompaktible optionen zur auswahl“). Der Server (engine.py) bietet nur an, was auf der Karte läuft, und lädt
// das Programm von stable-diffusion.cpp beim ersten Wechsel. Seit 0.5.38 (Nutzer 24.11.2026: „bau ROCm für RX 5000 und
// 6000 so ein. keine zluda.“) auf RX 5000 und RX 6500/6400 zusätzlich „ComfyUI (ROCm, experimentell)“ neben Vulkan.
import { useCallback, useEffect, useState } from 'react'
import { api, type EngineId, type EngineState, type SdcppBackend } from '../api'
import { t } from '../i18n'

type BackendChoice = 'auto' | SdcppBackend

/** Gemessen auf der RTX 5060 Ti 16 GB, Sekunden je Auftrag samt Laden (notizen/gpu.md, „Rechenweg“) */
export const ENGINE_MEASURED = {
  sdxl: { comfyui: 15, cuda: 23, vulkan: 24 },
  wan: { comfyui: 125, cuda: 168, vulkan: 182 },
}

/** Zustand vom Server; während das Programm lädt, alle 1,5 s neu */
export function useEngine(): [EngineState | null, (s: EngineState) => void] {
  const [st, setSt] = useState<EngineState | null>(null)
  const load = useCallback(() => {
    api.engine().then(setSt).catch(() => { /* älterer Server ohne /api/engine */ })
  }, [])
  useEffect(load, [load])
  const loading = !!st?.install && !st.install.error
  useEffect(() => {
    if (!loading) return
    const id = window.setInterval(load, 1500)
    return () => window.clearInterval(id)
  }, [loading, load])
  return [st, setSt]
}

function engineLabel(id: EngineId, st: EngineState): string {
  if (id === 'auto') return t('Auto (empfohlen)', 'Auto (recommended)')
  if (id === 'comfyui') {
    if (st.rocm_optional) return t('ComfyUI (ROCm, experimentell)', 'ComfyUI (ROCm, experimental)')
    return st.vendor === 'amd' ? 'ComfyUI (ROCm)' : 'ComfyUI (CUDA)'
  }
  return 'stable-diffusion.cpp'
}

function backendLabel(b: EngineState['backends'][number]): string {
  const name = b.id === 'auto' ? 'Auto' : b.id === 'cuda' ? 'CUDA' : 'Vulkan'
  if (b.id === 'auto' || b.installed) return name
  return t(`${name} · lädt ${b.download_mb} MB`, `${name} · downloads ${b.download_mb} MB`)
}

const sec = (s: number) => `${Math.round(s)} s`

function measuredLine(): string {
  const m = ENGINE_MEASURED
  if (!m.sdxl.comfyui) return ''
  return t(
    ` Gemessen auf einer RTX 5060 Ti: SDXL 1024² mit ComfyUI ${sec(m.sdxl.comfyui)}, sd.cpp CUDA ${sec(m.sdxl.cuda)}, Vulkan ${sec(m.sdxl.vulkan)}; Wan 1.3B 2 s Video ${sec(m.wan.comfyui)}, ${sec(m.wan.cuda)} und ${sec(m.wan.vulkan)}.`,
    ` Measured on an RTX 5060 Ti: SDXL 1024² with ComfyUI ${sec(m.sdxl.comfyui)}, sd.cpp CUDA ${sec(m.sdxl.cuda)}, Vulkan ${sec(m.sdxl.vulkan)}; Wan 1.3B 2 s of video ${sec(m.wan.comfyui)}, ${sec(m.wan.cuda)} and ${sec(m.wan.vulkan)}.`,
  )
}

/** RX 5000, RX 6500/6400 (seit 0.5.38): ROCm ist eingerichtet, Auto bleibt Vulkan, bis ROCm dort gemessen ist */
function optionalTip(id: EngineId, st: EngineState): string {
  const vulkan = st.engines.includes('sdcpp')
  if (id === 'comfyui') {
    return t('ComfyUI rechnet alles mit AMDs ROCm auf der Karte: alle Modelle, die in den Grafikspeicher passen, nicht nur SDXL und Wan 2.1 1.3B. Experimentell: AMDs Pakete für diese Karte sind neu und hier ungemessen, auf der RX 5000 berichten Nutzer anderer Programme von schwacher Leistung. Läuft etwas nicht, zurück auf Auto und bitte über „Problem melden“ berichten. Beim Wechsel startet ComfyUI neu.',
      'ComfyUI computes everything with AMD\'s ROCm on the card: every model that fits into the graphics memory, not just SDXL and Wan 2.1 1.3B. Experimental: AMD\'s packages for this card are new and unmeasured here; on the RX 5000, users of other programs report weak performance. If something does not work, go back to Auto and please tell us via "Report a problem". ComfyUI restarts when you switch.')
  }
  if (id === 'auto' && !vulkan) {
    return t('Vulkan sieht diese Karte nicht: ComfyUI rechnet über ROCm (experimentell).',
      'Vulkan does not see this card: ComfyUI computes through ROCm (experimental).')
  }
  const vk = t('Bilder (SDXL) und Videos (Wan 2.1 1.3B) über stable-diffusion.cpp mit Vulkan, Ton und Stimme über audio.cpp, alles andere auf dem Prozessor.',
    'Images (SDXL) and videos (Wan 2.1 1.3B) through stable-diffusion.cpp with Vulkan, sound and voice through audio.cpp, everything else on the processor.')
  if (id === 'sdcpp') return t('Wie Auto: ', 'Same as Auto: ') + vk
  return vk + ' ' + t('Die Vorgabe, bis ROCm auf dieser Karte gemessen ist.', 'The default until ROCm is measured on this card.')
}

function engineTip(id: EngineId, st: EngineState): string {
  if (st.rocm_optional) return optionalTip(id, st)
  if (id === 'auto') {
    return st.cpu_mode
      ? t('Bilder (SDXL) und Videos (Wan 2.1 1.3B) über stable-diffusion.cpp mit Vulkan, Ton und Stimme über audio.cpp, alles andere auf dem Prozessor.',
        'Images (SDXL) and videos (Wan 2.1 1.3B) through stable-diffusion.cpp with Vulkan, sound and voice through audio.cpp, everything else on the processor.')
      : t('ComfyUI rechnet alles: auf dieser Karte am schnellsten, mit allen Modellen und Funktionen.',
        'ComfyUI computes everything: the fastest on this card, with all models and features.')
  }
  if (id === 'comfyui') {
    return st.vendor === 'amd'
      ? t('Alle Modelle, die ROCm rechnet, mit allen Funktionen. Erste Wahl auf Radeon ab RX 6600.',
        'All models ROCm computes, with all features. The first choice on Radeon from the RX 6600.')
      : t('Alle Modelle mit allen Funktionen: NVFP4 auf RTX 50, Video mit Ton, 3D, Restaurieren. Erste Wahl auf NVIDIA.',
        'All models with all features: NVFP4 on RTX 50, video with sound, 3D, restoring. The first choice on NVIDIA.')
  }
  if (st.cpu_mode) {
    return t('Der Weg auf die Karte, wenn PyTorch sie nicht kennt: SDXL-Bilder und Wan 2.1 1.3B über Vulkan.',
      'The way onto the card when PyTorch does not know it: SDXL images and Wan 2.1 1.3B through Vulkan.')
  }
  return t('Ein kleines Programm ohne PyTorch rechnet SDXL-Bilder und Wan 2.1 1.3B. Alle anderen Modelle und was sd.cpp fehlt (ControlNet, Referenzbilder, Video-LoRAs) rechnet weiter ComfyUI.',
    'A small program without PyTorch computes SDXL images and Wan 2.1 1.3B. All other models and what sd.cpp lacks (ControlNet, reference images, video LoRAs) stay with ComfyUI.') + measuredLine()
}

function backendTip(b: BackendChoice, st: EngineState): string {
  if (b === 'auto') return t('Auto: CUDA auf NVIDIA, sonst Vulkan.', 'Auto: CUDA on NVIDIA, otherwise Vulkan.')
  if (b === 'cuda') {
    return t('CUDA: der schnellere Weg auf NVIDIA. Lädt einmalig rund 1 GB (Programm und CUDA-Laufzeit).',
      'CUDA: the faster way on NVIDIA. Downloads about 1 GB once (program and CUDA runtime).')
  }
  return st.vendor === 'nvidia'
    ? t('Vulkan: zum Vergleichen, wie es auf Radeon- und Intel-Karten läuft; auf NVIDIA langsamer als CUDA. Lädt 30 MB.',
      'Vulkan: to compare how it runs on Radeon and Intel cards; slower than CUDA on NVIDIA. Downloads 30 MB.')
    : t('Vulkan: läuft auf Radeon- und Intel-Karten, auch ohne ROCm.', 'Vulkan: runs on Radeon and Intel cards, also without ROCm.')
}

function nowText(st: EngineState): string {
  const e = st.effective
  if (e.engine === 'comfyui' && st.rocm_optional) {
    return t('Gerade rechnet ComfyUI mit ROCm auf der Karte (experimentell).', 'ComfyUI is computing with ROCm on the card now (experimental).')
  }
  if (e.engine === 'comfyui') return t('Gerade rechnet ComfyUI.', 'ComfyUI is computing now.')
  const name = `stable-diffusion.cpp (${e.backend === 'cuda' ? 'CUDA' : 'Vulkan'})`
  if (!st.ready) return t(`${name} lädt noch; bis dahin rechnet ComfyUI.`, `${name} is still downloading; ComfyUI computes until then.`)
  return st.cpu_mode
    ? t(`Gerade rechnet ${name} Bilder und Videos.`, `${name} is computing images and videos now.`)
    : t(`Gerade rechnet ${name} SDXL und Wan 2.1 1.3B, ComfyUI den Rest.`, `${name} is computing SDXL and Wan 2.1 1.3B now, ComfyUI the rest.`)
}

/** Kurzform für Zusammenfassungen („Deine Hardware“, Kopfleiste) */
export function engineShort(st: EngineState | null): string {
  if (!st) return ''
  const e = st.effective
  return e.engine === 'sdcpp' ? `sd.cpp (${e.backend === 'cuda' ? 'CUDA' : 'Vulkan'})` : 'ComfyUI'
}

/** Auswahl Rechenweg und sd.cpp-Modus mit Tipp; null, wenn auf diesem Rechner nichts zu wählen ist */
export function EngineChoice({ onChanged }: { onChanged?: () => void }) {
  const [st, setSt] = useEngine()
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  if (!st || st.engines.length < 2) return null

  const set = async (a: { engine?: EngineId; sdcpp_backend?: BackendChoice }) => {
    setBusy(true)
    setErr(null)
    try {
      setSt(await api.setEngine(a))
      onChanged?.()
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }
  // Eine Wahl, die auf dieser Karte nicht läuft (Karte gewechselt), gilt als Auto
  const engine: EngineId = st.engines.includes(st.engine) ? st.engine : 'auto'
  const backend: BackendChoice = st.backends.some((b) => b.id === st.sdcpp_backend) ? st.sdcpp_backend : 'auto'
  const showBackend = st.backends.length > 0 && (engine === 'sdcpp' || st.effective.engine === 'sdcpp')
  const inst = st.install
  // Ohne CUDA/ROCm lädt der Server auch audio.cpp nach, wenn das Setup die Vulkan-Engines nicht einrichten konnte
  const instName = !inst ? '' : inst.backend === 'audio' ? 'audio.cpp (Vulkan)'
    : `stable-diffusion.cpp (${inst.backend === 'cuda' ? 'CUDA' : 'Vulkan'})`

  return (
    <div className="engine-choice">
      <div className="engine-head">{t('Rechenweg für Bilder und Videos', 'Compute engine for images and videos')}</div>
      <label className="engine-row">
        <span>Engine</span>
        <select value={engine} disabled={busy} onChange={(e) => set({ engine: e.target.value as EngineId })}>
          {st.engines.map((id) => <option key={id} value={id}>{engineLabel(id, st)}</option>)}
        </select>
      </label>
      <p className="engine-tip muted small">{engineTip(engine, st)}</p>
      {showBackend && (
        <>
          <label className="engine-row">
            <span>{t('sd.cpp-Modus', 'sd.cpp mode')}</span>
            <select value={backend} disabled={busy}
              onChange={(e) => set({ sdcpp_backend: e.target.value as BackendChoice })}>
              {st.backends.map((b) => <option key={b.id} value={b.id}>{backendLabel(b)}</option>)}
            </select>
          </label>
          <p className="engine-tip muted small">{backendTip(backend, st)}</p>
        </>
      )}
      {inst && !inst.error && (
        <div className="engine-install">
          <span>{t(`Lädt ${instName}: ${Math.round(inst.done / 1e6)} von ${Math.round(inst.total / 1e6)} MB`,
            `Downloading ${instName}: ${Math.round(inst.done / 1e6)} of ${Math.round(inst.total / 1e6)} MB`)}</span>
          <span className="vram-bar"><span className="vram-fill" style={{ width: `${Math.min(100, (inst.done / Math.max(1, inst.total)) * 100)}%` }} /></span>
        </div>
      )}
      {inst?.error && (
        <div className="engine-error">
          <span>{t('Laden fehlgeschlagen: ', 'Download failed: ')}{inst.error}</span>
          <button type="button" className="btn small ghost" disabled={busy}
            onClick={() => set({ engine, sdcpp_backend: backend })}>{t('Erneut versuchen', 'Try again')}</button>
        </div>
      )}
      {err && <div className="engine-error">{err}</div>}
      <p className="engine-now small">{nowText(st)}</p>
    </div>
  )
}
