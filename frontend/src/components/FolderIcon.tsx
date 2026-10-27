// Ordner als Strichzeichnung in Textfarbe (seit 0.5.15): Material im Studio, Verlauf und Generator zeigen damit die
// Projektordner. Passt in der Größe zu ☰ ▦ ⭱ neben dem Hochladen-Knopf.

export function FolderIcon({ size = 13 }: { size?: number }) {
  return (
    <svg className="st-folder-icon" viewBox="0 0 16 16" width={size} height={size} aria-hidden="true">
      <path d="M1.5 3.2h4.6l1.5 1.7h6.9v7.9H1.5z" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinejoin="round" />
    </svg>
  )
}
