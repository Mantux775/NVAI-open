// Englische Texte aller t('Deutsch', 'English')-Aufrufe der Weboberflaeche, fuer die Sprachpakete (zh, fr).
// Vorlagen mit ${...} werden zu {0}, {1} ... in der Reihenfolge im Text; so sucht auch i18n.ts danach.
// Die Pruef-App (src/review) laedt keine Sprachpakete und bleibt aussen vor.
//
//   node frontend/scripts/langpack-strings.cjs <frontend/src> <ausgabe.json>
const fs = require('fs')
const path = require('path')
const ts = require(path.join(__dirname, '..', 'node_modules', 'typescript'))

const root = path.resolve(process.argv[2])
const outFile = process.argv[3]
const found = new Set()
const notLiteral = []

function walk(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name)
    if (e.isDirectory()) {
      if (path.relative(root, p).replace(/\\/g, '/') !== 'review') walk(p)
    } else if (/\.tsx?$/.test(e.name) && !e.name.endsWith('.d.ts')) scan(p)
  }
}

function literal(node) {
  if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) return node.text
  if (ts.isTemplateExpression(node)) {
    let s = node.head.text
    node.templateSpans.forEach((sp, i) => { s += '{' + i + '}' + sp.literal.text })
    return s
  }
  if (ts.isParenthesizedExpression(node)) return literal(node.expression)
  if (ts.isBinaryExpression(node) && node.operatorToken.kind === ts.SyntaxKind.PlusToken) {
    const a = literal(node.left)
    const b = literal(node.right)
    // Zwei Vorlagen aneinander: die Platzhalter der rechten weiterzaehlen
    if (a !== null && b !== null) {
      const n = (a.match(/\{\d+\}/g) || []).length
      return a + b.replace(/\{(\d+)\}/g, (_, i) => '{' + (Number(i) + n) + '}')
    }
  }
  return null
}

function scan(file) {
  const src = fs.readFileSync(file, 'utf8')
  const kind = file.endsWith('x') ? ts.ScriptKind.TSX : ts.ScriptKind.TS
  const sf = ts.createSourceFile(file, src, ts.ScriptTarget.Latest, true, kind)
  const visit = (n) => {
    if (ts.isCallExpression(n) && ts.isIdentifier(n.expression) && n.expression.text === 't' && n.arguments.length === 2) {
      const en = literal(n.arguments[1])
      if (en !== null) found.add(en)
      else {
        const { line } = sf.getLineAndCharacterOfPosition(n.getStart())
        notLiteral.push(path.relative(root, file).replace(/\\/g, '/') + ':' + (line + 1))
      }
    }
    ts.forEachChild(n, visit)
  }
  visit(sf)
}

walk(root)
fs.writeFileSync(outFile, JSON.stringify({ strings: [...found].sort(), not_literal: notLiteral }))
