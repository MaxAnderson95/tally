import { useEffect, useRef, useState } from 'react'
import { groupIsStale } from './api'
import { activityRanges, costLabel, decodeActivity, tokenLabel, type ActivityRange, type ActivityResponse, type Aggregate } from './activity'

function Totals({ value }: { value: Aggregate }) {
  return <><p className="activity-total">{tokenLabel(value)}</p>
    {value.missingUsageRows > 0 && <p>Usage missing for {value.missingUsageRows} of {value.rows} records; token subtotal is incomplete.</p>}
    <p>{costLabel(value)}</p>
    <p>API-equivalent estimate: {value.estimate.status === 'empty' ? 'No recorded activity' : 'Unpriced; reviewed rates not bundled'}</p>
    <details><summary>Token and cost coverage</summary><dl>
      <dt>Retained records</dt><dd>{value.rows}</dd>
      {value.tokens && Object.entries(value.tokens).map(([key, count]) => <div className="detail-window" key={key}><dt>{{ input: 'Noncached input', output: 'Visible output', reasoning: 'Reasoning', cacheRead: 'Cache read', cacheWrite: 'Cache write', total: 'Total' }[key]}</dt><dd>{count.toLocaleString()}</dd></div>)}
      <dt>Rows with cost</dt><dd>{value.recordedCost.rowsWithCost}</dd><dt>Cost missing</dt><dd>{value.recordedCost.missingCostRows}</dd><dt>Ambiguous zero costs</dt><dd>{value.recordedCost.ambiguousZeroRows}</dd>
      <dt>Unpriced rows</dt><dd>{value.estimate.coverage.unpricedRows}</dd><dt>Usage missing</dt><dd>{value.missingUsageRows}</dd>
    </dl></details></>
}

export function RecordedActivity({ refresh, onObserved }: { refresh: unknown; onObserved: (date: string | null) => void }) {
  const [range, setRange] = useState<ActivityRange>('today')
  const [response, setResponse] = useState<ActivityResponse>()
  const [error, setError] = useState<string>()
  const build = useRef<string>(undefined)
  useEffect(() => {
    let stopped = false, inFlight = false
    const controller = new AbortController()
    async function poll() {
      if (document.hidden || inFlight) return
      inFlight = true
      try {
        const result = await fetch(`/api/v1/activity?range=${range}`, { cache: 'no-store', signal: AbortSignal.any([controller.signal, AbortSignal.timeout(10_000)]) })
        if (!result.ok) throw new Error(`Activity connection failed (HTTP ${result.status}).`)
        const next = decodeActivity(await result.text())
        if (build.current && build.current !== next.status.appBuild) { location.reload(); return }
        build.current = next.status.appBuild
        if (!stopped) { setResponse(next); setError(undefined); onObserved(next.activity.observedAt) }
      } catch (failure) { if (!stopped) setError(failure instanceof Error ? failure.message : 'Activity connection failed.') }
      finally { inFlight = false }
    }
    void poll()
    const timer = setInterval(() => void poll(), 15_000)
    const visible = () => { if (!document.hidden) void poll() }
    document.addEventListener('visibilitychange', visible)
    return () => { stopped = true; controller.abort(); clearInterval(timer); document.removeEventListener('visibilitychange', visible) }
  }, [range, refresh, onObserved])
  const group = response?.activity
  const data = group?.data
  const exact = (value: string | null) => value ? new Date(value).toLocaleString(undefined, { timeZone: data?.timezone ?? response?.status.timezone }) : 'Unavailable'
  const max = Math.max(1, ...data?.trend.days.map(day => day.totals.tokens?.total ?? 0) ?? [])
  return <aside className="activity-region" aria-label="Recorded OpenCode activity">
    <h2>Recorded OpenCode activity</h2>
    <div className="activity-ranges" aria-label="Activity range">{activityRanges.map(item => <button key={item.value} aria-pressed={range === item.value} onClick={() => setRange(item.value)}>{item.label}</button>)}</div>
    {error && <p role="alert">{error} Last view is stale.</p>}
    {group?.error && <p role="alert">{group.error.message}</p>}
    <p>{group?.refreshing ? 'Scanning…' : !group || groupIsStale(group) || error ? 'Stale / unavailable' : 'Current scan'} · {exact(group?.observedAt ?? null)}</p>
    {!data ? <p>Activity unavailable</p> : <>
      <p>{activityRanges.find(item => item.value === data.range)?.label}{data.range !== range && ' (last view; requested range pending)'} · {data.timezone}</p>
      <p>Partial history · Provider/local-database attribution, not Accounts</p>
      <Totals value={data.totals} />
      <p>30-calendar-day token context; selected days are solid.</p>
      <div className="activity-trend" role="img" aria-label="30-day recorded token trend">
        {data.trend.days.map(day => <div key={day.date} className={day.selected ? 'selected' : ''} style={{ height: `${Math.max(2, (day.totals.tokens?.total ?? 0) / max * 100)}%` }} title={`${day.date}: ${tokenLabel(day.totals)}${day.totals.missingUsageRows ? '; usage missing' : ''}`} />)}
      </div>
      <div className="window-heading"><span>{data.trend.days[0]?.date}</span><span>{data.trend.days.at(-1)?.date}</span></div>
      <details><summary>Daily values</summary>{data.trend.days.map(day => <p key={day.date}>{day.date}{day.selected ? ' (selected)' : ''}: {tokenLabel(day.totals)}; {day.totals.missingUsageRows} usage missing</p>)}</details>
      {data.providers.map(provider => <details key={provider.provider}><summary>{provider.label}: {tokenLabel(provider.totals)}</summary><Totals value={provider.totals} />{provider.models.map(model => <details key={model.modelId}><summary>{model.modelId}</summary><Totals value={model.totals} /></details>)}</details>)}
      <details><summary>Source, pricing, and freshness</summary>
        {data.source.qualifications.map(note => <p key={note}>{note}</p>)}
        <dl><dt>Range start</dt><dd>{exact(data.startAt)}</dd><dt>Exclusive end</dt><dd>{exact(data.endAt)}</dd><dt>First retained</dt><dd>{exact(data.source.firstRetainedAt)}</dd><dt>Last retained</dt><dd>{exact(data.source.lastRetainedAt)}</dd><dt>Populated retained days</dt><dd>{data.source.populatedDays} (not continuous coverage)</dd><dt>Last attempt</dt><dd>{exact(group?.lastAttemptAt ?? null)}</dd><dt>Next scan</dt><dd>{exact(group?.nextAttemptAt ?? null)}</dd><dt>Pricing revision</dt><dd>{data.pricing.revision} ({data.pricing.observedOn})</dd></dl>
      </details>
    </>}
  </aside>
}
