import { earlyLimitDate, limitLabel, percentage, resetLabel, type QuotaWindow } from './api'
import { Swap } from './motion'

export function Flame() {
  return <svg className="flame" viewBox="0 0 20 20" aria-hidden="true"><path d="M11 1c1 5-3 5-3 9-2-1-2-3-2-3-5 6-2 12 4 12s9-7 4-12c0 3-2 3-2 3 2-5 0-8-1-9Z" fill="currentColor" /></svg>
}

export function Warning() {
  return <svg width="16" height="16" viewBox="0 0 20 20" aria-hidden="true"><path d="M10 2.5 18.5 17.5h-17Z M10 8v4.5 M10 14.5v.5" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round" strokeLinecap="round" /></svg>
}

export function TallyMeter({ percent, label, uncertain = false, pace = null }: { percent: number | null; label: string; uncertain?: boolean; pace?: number | null }) {
  return <div className={`meter${uncertain ? ' uncertain' : ''}`} role="meter" aria-label={label} aria-valuemin={0} aria-valuemax={100} aria-valuenow={percent ?? undefined} aria-valuetext={`${percentage(percent)} remaining`}>
    <div className="meter-track">{percent !== null && <div className="meter-fill" style={{ width: `${percent}%` }} />}</div>
    {pace !== null && <span className="meter-pace" style={{ left: `${pace}%` }} title="Where you would be at an even pace" />}
  </div>
}

export function QuotaRow({ window, stale, now }: { window: QuotaWindow; stale: boolean; now: number }) {
  const limit = earlyLimitDate(window, stale, now)
  const pace = limit !== null && window.resetAt && window.durationSeconds !== null && window.durationSeconds > 0
    ? Math.min(100, Math.max(0, (Date.parse(window.resetAt) - now) / (window.durationSeconds * 1000) * 100)) : null
  const tone = window.remainingPercent === 0 || (limit !== null && limit <= now) ? 'empty' : limit !== null ? 'burning' : 'steady'
  return <div className="window" data-tone={tone}>
    <span className="window-label">{window.label}</span>
    <TallyMeter percent={window.remainingPercent} label={window.label} uncertain={window.durationSeconds === null || window.remainingPercent === null} pace={pace} />
    <Swap className="window-percent" value={percentage(window.remainingPercent)} />
    <p className="window-timing">
      <span>{window.durationSeconds === null && 'Duration unknown. '}{resetLabel(window, now)}</span>
      {limit !== null && <span className="window-limit" title="At your average rate, this window runs out before it resets. The tall mark shows where an even pace would put you."><Flame />{limitLabel(limit, now)}</span>}
    </p>
  </div>
}
