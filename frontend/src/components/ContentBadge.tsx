import type { ModelInfo } from '../api'
import { t } from '../i18n'

const LABEL: Record<string, string> = {
  uncensored: t('unzensiert', 'uncensored'),
  partial: t('teilweise zensiert', 'partly censored'),
  censored: t('zensiert', 'censored'),
}

/**
 * Zensiert oder nicht (Bild- und Videomodelle), mit Beleg im Tooltip. Ohne Einstufung
 * steht "Zensur unbekannt" -- lieber das als eine geratene Angabe (server/nvai/content.py).
 */
export function ContentBadge({ model }: {
  model: Pick<ModelInfo, 'kind' | 'workflow' | 'content' | 'content_note' | 'content_source'>
}) {
  // Nur Generatoren: eine VAE oder ein ControlNet erzeugt selbst nichts.
  if ((model.kind !== 'image' && model.kind !== 'video') || !model.workflow) return null
  const level = model.content
  const title = level
    ? `${model.content_note}${model.content_source ? `\n${t('Quelle', 'Source')}: ${model.content_source}` : ''}`
    : t('Keine verlässliche Angabe des Herstellers gefunden.', 'No reliable statement from the maker found.')
  return (
    <span className={`badge content-${level ?? 'unknown'}`} title={title}>
      {level ? LABEL[level] : t('Zensur unbekannt', 'filtering unknown')}
    </span>
  )
}
