import { countdown, earlyLimitDate, percentage, resetLabel, type QuotaWindow } from './api'

export function QuotaRow({ window, stale, now }: { window: QuotaWindow; stale: boolean; now: number }) {
  const limit = earlyLimitDate(window, stale, now)
  const expected = limit !== null && window.resetAt && window.durationSeconds !== null && window.durationSeconds > 0
    ? Math.min(100, Math.max(0, (Date.parse(window.resetAt) - now) / (window.durationSeconds * 1000) * 100)) : null
  return <section className="quota">
    <div className="window-heading"><span>{window.label}</span><strong>{percentage(window.remainingPercent)}</strong></div>
    <div className={`quota-meter ${limit !== null ? 'running-out' : ''}`}>
      <div className={`bar ${window.durationSeconds === null || window.remainingPercent === null ? 'uncertain' : ''}`} aria-label={`${percentage(window.remainingPercent)} remaining`}>
        {window.remainingPercent !== null && <div style={{ width: `${window.remainingPercent}%` }} />}
      </div>
      {expected !== null && <span className="pace-marker" style={{ left: `${expected}%` }} title="Remaining allowance at an even pace" />}
    </div>
    {window.resetAt && <div className="quota-timing">
      <p className="timing">{window.durationSeconds === null && 'Duration unknown. '}{resetLabel(window, now)}</p>
      {limit !== null && <p className="pace-warning" title="At your average usage rate, this quota is projected to run out before reset. The marker shows the remaining allowance at an even pace.">
        <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M11 1c1 5-3 5-3 9-2-1-2-3-2-3-5 6-2 12 4 12s9-7 4-12c0 3-2 3-2 3 2-5 0-8-1-9Z" fill="currentColor" /></svg>
        {limit <= now ? 'Limit reached' : `Limit in ${countdown(limit, now)}`}
      </p>}
    </div>}
  </section>
}
