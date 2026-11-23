import { useEffect, useRef, useState } from 'react'
import { t } from '../i18n'

/**
 * Foto für „Person aus einem Foto“ zuschneiden (Nutzer 23.11.2026: „ausgewähltes bild zuschneiden, mit tipp und
 * beispiel kontur wieviel zu sehen sein sollte“). Rahmen im Hochformat 3:4, verschieben durch Ziehen, Größe an den
 * Ecken oder mit dem Mausrad; die gestrichelte Kontur zeigt Kopf und Schultern so groß, wie sie im Ausschnitt sein
 * sollten. Geschnitten wird im Browser in voller Auflösung (lange Seite höchstens 2048 px), das Ergebnis kommt als
 * JPEG zurück und wird wie ein hochgeladenes Foto gespeichert.
 */

const RATIO = 4 / 3 // Höhe zu Breite des Ausschnitts
const MIN_W = 96
const MAX_OUT = 2048
// Darunter wird das Gesicht unscharf: Referenzen rechnen die Modelle auf rund 1 MP hoch
const SMALL_H = 640

type Crop = { x: number; y: number; w: number }
type Drag = { kind: 'move'; px: number; py: number; start: Crop } | { kind: 'corner'; cx: 1 | -1; cy: 1 | -1; ax: number; ay: number }

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v))

export function PhotoCrop({ url, name, onDone, onClose }: {
  url: string
  name: string
  onDone: (file: File) => Promise<void> | void
  onClose: () => void
}) {
  const img = useRef<HTMLImageElement>(null)
  const [dims, setDims] = useState<{ w: number; h: number } | null>(null)
  const [scale, setScale] = useState(1) // Anzeige-Pixel je Bild-Pixel
  const [crop, setCrop] = useState<Crop | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const drag = useRef<Drag | null>(null)

  const maxW = (d: { w: number; h: number }) => Math.min(d.w, d.h / RATIO)
  const fit = (c: Crop, d: { w: number; h: number }): Crop => {
    const w = clamp(c.w, Math.min(MIN_W, maxW(d)), maxW(d))
    return { w, x: clamp(c.x, 0, d.w - w), y: clamp(c.y, 0, d.h - w * RATIO) }
  }

  const measure = () => {
    const el = img.current
    if (!el || !el.naturalWidth) return
    setScale(el.getBoundingClientRect().width / el.naturalWidth)
  }
  const onLoad = () => {
    const el = img.current
    if (!el) return
    const d = { w: el.naturalWidth, h: el.naturalHeight }
    setDims(d)
    measure()
    // Anfang: 90 % der möglichen Größe, waagrecht mittig, eher oben (Köpfe sitzen meist in der oberen Hälfte)
    const w = maxW(d) * 0.9
    setCrop(fit({ w, x: (d.w - w) / 2, y: (d.h - w * RATIO) * 0.3 }, d))
  }

  useEffect(() => {
    window.addEventListener('resize', measure)
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !busy) onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => {
      window.removeEventListener('resize', measure)
      window.removeEventListener('keydown', onKey)
    }
  }, [busy, onClose])

  const toImage = (e: React.PointerEvent | PointerEvent) => {
    const r = img.current!.getBoundingClientRect()
    return { x: (e.clientX - r.left) / scale, y: (e.clientY - r.top) / scale }
  }
  // Zeiger festhalten, damit das Ziehen auch über den Rand hinaus weiterläuft; ohne aktiven Zeiger wirft der Browser
  const capture = (e: React.PointerEvent) => {
    try {
      ;(e.target as Element).setPointerCapture(e.pointerId)
    } catch {
      /* kein aktiver Zeiger */
    }
  }
  const startMove = (e: React.PointerEvent) => {
    if (!crop) return
    e.preventDefault()
    capture(e)
    drag.current = { kind: 'move', px: e.clientX, py: e.clientY, start: crop }
  }
  const startCorner = (cx: 1 | -1, cy: 1 | -1) => (e: React.PointerEvent) => {
    if (!crop) return
    e.preventDefault()
    e.stopPropagation()
    capture(e)
    // Die gegenüberliegende Ecke bleibt stehen
    drag.current = { kind: 'corner', cx, cy, ax: cx > 0 ? crop.x : crop.x + crop.w,
      ay: cy > 0 ? crop.y : crop.y + crop.w * RATIO }
  }
  const onMove = (e: React.PointerEvent) => {
    const d = drag.current
    if (!d || !dims) return
    if (d.kind === 'move') {
      setCrop(fit({ ...d.start, x: d.start.x + (e.clientX - d.px) / scale, y: d.start.y + (e.clientY - d.py) / scale },
        dims))
      return
    }
    const p = toImage(e)
    const room = Math.min(d.cx > 0 ? dims.w - d.ax : d.ax, (d.cy > 0 ? dims.h - d.ay : d.ay) / RATIO)
    const w = clamp(Math.max((p.x - d.ax) * d.cx, ((p.y - d.ay) * d.cy) / RATIO), Math.min(MIN_W, room), room)
    setCrop({ w, x: d.cx > 0 ? d.ax : d.ax - w, y: d.cy > 0 ? d.ay : d.ay - w * RATIO })
  }
  const endDrag = () => {
    drag.current = null
  }
  const onWheel = (e: React.WheelEvent) => {
    if (!crop || !dims) return
    const w = clamp(crop.w * (e.deltaY > 0 ? 1.06 : 1 / 1.06), Math.min(MIN_W, maxW(dims)), maxW(dims))
    const cx = crop.x + crop.w / 2
    const cy = crop.y + (crop.w * RATIO) / 2
    setCrop(fit({ w, x: cx - w / 2, y: cy - (w * RATIO) / 2 }, dims))
  }

  const outH = crop ? Math.round(Math.min(crop.w * RATIO, MAX_OUT)) : 0
  const outW = crop ? Math.round((outH / RATIO)) : 0
  const apply = async () => {
    const el = img.current
    if (!el || !crop) return
    setBusy(true)
    setError(null)
    try {
      const canvas = document.createElement('canvas')
      canvas.width = outW
      canvas.height = outH
      const ctx = canvas.getContext('2d')
      if (!ctx) throw new Error('canvas')
      ctx.imageSmoothingQuality = 'high'
      ctx.drawImage(el, crop.x, crop.y, crop.w, crop.w * RATIO, 0, 0, outW, outH)
      const blob = await new Promise<Blob | null>((res) => canvas.toBlob(res, 'image/jpeg', 0.95))
      if (!blob) throw new Error(t('Zuschneiden fehlgeschlagen', 'Cropping failed'))
      const base = name.replace(/\.[^.]+$/, '') || 'foto'
      await onDone(new File([blob], `${base}_zuschnitt.jpg`, { type: 'image/jpeg' }))
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
      setBusy(false)
    }
  }

  return (
    <div className="lightbox photo-crop" onClick={() => !busy && onClose()}>
      <div className="photo-crop-stage" onClick={(e) => e.stopPropagation()} onWheel={onWheel}
        onPointerMove={onMove} onPointerUp={endDrag} onPointerCancel={endDrag}>
        <img ref={img} src={url} alt="" onLoad={onLoad} draggable={false} />
        {crop && (
          <div className="photo-crop-frame" onPointerDown={startMove}
            style={{ left: crop.x * scale, top: crop.y * scale, width: crop.w * scale, height: crop.w * RATIO * scale }}>
            {/* Beispielkontur: Kopf mit etwas Luft darüber, Kinn knapp über der Mitte, Schultern am unteren Rand */}
            <svg viewBox="0 0 300 400" preserveAspectRatio="none" aria-hidden="true">
              <g fill="none" strokeLinecap="round" strokeLinejoin="round">
                {[{ stroke: 'rgba(0,0,0,0.55)', width: 4, dash: undefined },
                  { stroke: 'rgba(255,255,255,0.9)', width: 2, dash: '7 5' }].map((s) => (
                  <g key={s.width} stroke={s.stroke} strokeWidth={s.width} strokeDasharray={s.dash}>
                    <path vectorEffect="non-scaling-stroke"
                      d="M150,48 C201,48 222,94 222,140 C222,196 192,246 150,246 C108,246 78,196 78,140 C78,94 99,48 150,48 Z" />
                    <path vectorEffect="non-scaling-stroke"
                      d="M124,234 C124,256 121,272 112,283 C80,293 42,303 24,340 L12,400 M176,234 C176,256 179,272 188,283 C220,293 258,303 276,340 L288,400" />
                  </g>
                ))}
                <path vectorEffect="non-scaling-stroke" d="M96,148 L204,148" stroke="rgba(255,255,255,0.45)"
                  strokeWidth={1} strokeDasharray="3 5" />
              </g>
            </svg>
            {([[-1, -1], [1, -1], [-1, 1], [1, 1]] as const).map(([cx, cy]) => (
              <span key={`${cx}${cy}`} className={`photo-crop-handle ${cy < 0 ? 't' : 'b'}${cx < 0 ? 'l' : 'r'}`}
                onPointerDown={startCorner(cx, cy)} />
            ))}
          </div>
        )}
      </div>
      <div className="lightbox-meta photo-crop-meta" onClick={(e) => e.stopPropagation()}>
        <p className="small">
          {t('Kopf und Schultern wie die gestrichelte Kontur: das Gesicht gerade von vorn und groß, über dem Kopf '
            + 'etwas Luft, unten bis knapp unter die Schultern, die Augen etwa auf der feinen Linie. Nichts vor dem '
            + 'Gesicht (Hand, Haare, Sonnenbrille). Ohrhörer, Brille oder Mütze nimmt das Modell mit ins Bild. Ist '
            + 'der Kopf schon größer als die Kontur (Selfie), passt das Foto auch ohne Zuschnitt. Verschieben durch '
            + 'Ziehen, Größe an den Ecken oder mit dem Mausrad.',
          'Head and shoulders like the dashed outline: the face straight on and large, a little room above the head, '
            + 'down to just below the shoulders, the eyes roughly on the fine line. Nothing in front of the face '
            + '(hand, hair, sunglasses). The model carries earphones, glasses or a cap over into the picture. If the '
            + 'head is already larger than the outline (selfie), the photo works without cropping too. Drag to move, '
            + 'resize at the corners or with the mouse wheel.')}
        </p>
        {crop && (
          <p className={outH < SMALL_H ? 'hint small warn' : 'muted small'}>
            {t(`Ausschnitt ${outW} × ${outH} px`, `Crop ${outW} × ${outH} px`)}
            {outH < SMALL_H && t(' – klein: das Gesicht wird eher unscharf, besser ein größeres Foto.',
              ' – small: the face tends to come out blurry, a larger photo works better.')}
          </p>
        )}
        {error && <p className="hint small warn">{error}</p>}
        <div className="lightbox-actions">
          <button className="btn small" disabled={!crop || busy} onClick={apply}>
            {busy ? t('speichert …', 'saving …') : t('Zuschneiden und als Foto nehmen', 'Crop and use as the photo')}
          </button>
          <button className="btn small ghost" disabled={busy} onClick={onClose}>{t('Abbrechen', 'Cancel')}</button>
        </div>
      </div>
    </div>
  )
}
