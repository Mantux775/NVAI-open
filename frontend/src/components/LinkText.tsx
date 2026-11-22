/** Text mit anklickbaren https-Adressen, z. B. der Lizenzanfrage im Warnkasten von MiniMax H3. */
export function LinkText({ text }: { text: string }) {
  const parts = text.split(/(https?:\/\/[^\s)]+[^\s).,;:!?])/)
  return (
    <>
      {parts.map((p, i) =>
        /^https?:\/\//.test(p)
          ? <a key={i} href={p} target="_blank" rel="noreferrer">{p.replace(/^https?:\/\//, '')}</a>
          : p,
      )}
    </>
  )
}
