// Prüf-App zu einer Datei machen: JS und CSS aus dist-review in die Seite einbetten → dist/NVAI-Pruefer.html.
// Von der Platte geöffnet (file://) darf die Seite nichts nachladen; ein verbliebener Verweis bricht den Bau ab.
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const dir = 'dist-review'
let html = readFileSync(join(dir, 'review.html'), 'utf8')
html = html.replace(/<script type="module" crossorigin src="\.\/(assets\/[^"]+\.js)"><\/script>/, (_, f) => {
  const js = readFileSync(join(dir, f), 'utf8').replace(/<\/script/gi, '<\\/script')
  return `<script type="module">${js}</script>`
})
html = html.replace(/<link rel="stylesheet" crossorigin href="\.\/(assets\/[^"]+\.css)">/, (_, f) =>
  `<style>${readFileSync(join(dir, f), 'utf8').replace(/<\/style/gi, '<\\/style')}</style>`)
if (/(src|href)="\.?\/?assets\//.test(html)) throw new Error('Prüf-App: nicht alles eingebettet')
writeFileSync(join('dist', 'NVAI-Pruefer.html'), html)
console.log(`dist/NVAI-Pruefer.html: ${(html.length / 1024).toFixed(0)} KB`)
