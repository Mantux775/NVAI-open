// Rechtsklick-Menü des Studios (Nutzer 27.10.2026: „rechtklick muss überall gehen“): eine kurze Liste an der
// Mausposition, Untermenüs beim Überfahren, Tastenkürzel rechts daneben. Schließt bei Klick daneben, Esc, Rollen
// und wenn das Fenster den Fokus verliert. Kein Browser-Dialog, nichts blockiert.

import { useEffect, useLayoutEffect, useRef, useState, type CSSProperties } from 'react'

export interface MenuItem {
  label: string
  /** Tastenkürzel, nur zur Anzeige */
  hint?: string
  onClick?: () => void
  disabled?: boolean
  /** Häkchen davor (aktuelle Art, eingeschaltet …) */
  checked?: boolean
  danger?: boolean
  items?: MenuItem[]
  /** Trennlinie davor */
  separator?: boolean
}

export interface MenuState {
  x: number
  y: number
  items: MenuItem[]
}

function List({ items, onClose, style }: { items: MenuItem[]; onClose: () => void; style: CSSProperties }) {
  const ref = useRef<HTMLDivElement>(null)
  const [open, setOpen] = useState<number | null>(null)
  const [pos, setPos] = useState(style)
  // Am Fensterrand nach innen rücken
  useLayoutEffect(() => {
    const el = ref.current
    if (!el) return
    const r = el.getBoundingClientRect()
    const next: CSSProperties = { ...style }
    if (r.right > window.innerWidth - 4) {
      if (style.left === '100%') {
        next.left = 'auto' // Untermenü links aufklappen
        next.right = '100%'
      } else next.left = Math.max(4, Number(style.left) - (r.right - window.innerWidth) - 8)
    }
    if (r.bottom > window.innerHeight - 4) {
      const top = (typeof style.top === 'number' ? style.top : 0) - (r.bottom - window.innerHeight) - 8
      next.top = style.position === 'fixed' ? Math.max(4, top) : top
    }
    setPos(next)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])
  return (
    <div className="st-menu" ref={ref} style={pos} onContextMenu={(e) => e.preventDefault()}>
      {items.map((it, i) => (
        <div key={i}>
          {it.separator && <div className="st-menu-sep" />}
          <div
            className={`st-menu-item${it.disabled ? ' disabled' : ''}${it.danger ? ' danger' : ''}${open === i ? ' open' : ''}`}
            onPointerEnter={() => setOpen(it.items ? i : null)}
            onClick={(e) => {
              e.stopPropagation()
              if (it.disabled || it.items) return
              onClose()
              it.onClick?.()
            }}
          >
            <span className="st-menu-check">{it.checked ? '✓' : ''}</span>
            <span className="st-menu-label">{it.label}</span>
            {it.hint && <span className="st-menu-hint">{it.hint}</span>}
            {it.items && <span className="st-menu-arrow">▸</span>}
            {it.items && open === i && !it.disabled && (
              <List items={it.items} onClose={onClose} style={{ position: 'absolute', left: '100%', top: -4 }} />
            )}
          </div>
        </div>
      ))}
    </div>
  )
}

export function ContextMenu({ menu, onClose }: { menu: MenuState | null; onClose: () => void }) {
  useEffect(() => {
    if (!menu) return
    const close = () => onClose()
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose()
    const onDown = (e: PointerEvent) => {
      if (!(e.target as HTMLElement)?.closest?.('.st-menu')) onClose()
    }
    window.addEventListener('pointerdown', onDown, true)
    window.addEventListener('keydown', onKey)
    window.addEventListener('blur', close)
    window.addEventListener('wheel', close, { passive: true })
    return () => {
      window.removeEventListener('pointerdown', onDown, true)
      window.removeEventListener('keydown', onKey)
      window.removeEventListener('blur', close)
      window.removeEventListener('wheel', close)
    }
  }, [menu, onClose])
  if (!menu) return null
  return (
    <div className="st-menu-layer">
      <List key={`${menu.x},${menu.y}`} items={menu.items} onClose={onClose} style={{ position: 'fixed', left: menu.x, top: menu.y }} />
    </div>
  )
}
