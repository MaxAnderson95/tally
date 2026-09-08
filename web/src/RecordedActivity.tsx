import { useEffect, useRef, useState } from 'react'
import { groupIsStale } from './api'
import { activityRanges, costLabel, decodeActivity, estimateLabel, estimateQualification, tokenLabel, type ActivityRange, type ActivityResponse, type Aggregate, type Tokens } from './activity'
import { providerName } from './ProviderLogo'

const currency = new Intl.NumberFormat(undefined, { style: 'currency', currency: 'USD', maximumFractionDigits: 2 })

function Components({ value }: { value: Tokens }) {
  return <>{Object.entries(value).map(([key, count]) => <div className="detail-window" key={key}><dt>{{ input: 'Noncached input', output: 'Visible output', reasoning: 'Reasoning', cacheRead: 'Cache read', cacheWrite: 'Cache write', total: 'Total' }[key]}</dt><dd>{count.toLocaleString()}</dd></div>)}</>
}

function Totals({ value }: { value: Aggregate }) {
  const estimate = value.estimate
  const amount = estimate.lower === null || estimate.upper === null ? 'Unpriced' : estimate.lower === estimate.upper ? currency.format(Number(estimate.lower)) : `${currency.format(Number(estimate.lower))} – ${currency.format(Number(estimate.upper))}`
  return <><div className="activity-metrics">
    <div><span>Recorded tokens</span><strong>{value.rows === 0 ? 'No activity' : value.tokens?.total.toLocaleString() ?? 'Unknown'}</strong><p>{value.rows.toLocaleString()} retained records{value.missingUsageRows > 0 && ` · ${value.missingUsageRows} missing usage`}</p></div>
    <div><span>API-equivalent {estimate.status === 'partial' ? 'subtotal' : 'estimate'}</span><strong>{estimate.status === 'empty' ? 'No activity' : amount}</strong><p>{estimate.status === 'partial' ? 'Partial · priced components only' : estimate.status === 'range' ? 'Range · reference pricing' : 'Reference pricing'} · rounded to cents</p></div>
    <div><span>Recorded cost</span><strong>{value.rows === 0 ? 'No activity' : value.recordedCost.amount === null ? 'Unavailable' : currency.format(Number(value.recordedCost.amount))}</strong><p>{value.recordedCost.amount === '0' ? 'Pricing provenance unknown' : 'As recorded by OpenCode'}</p></div>
  </div>
    <p className="coverage-note">{estimateQualification(estimate)}{value.missingUsageRows > 0 && ' Token totals are incomplete.'}</p>
    <details className="coverage-details"><summary>Coverage and exact values</summary>
      <p>{tokenLabel(value)}</p><p>{costLabel(value)}</p><p>{estimateLabel(estimate)}</p>
      {estimate.exclusions.length > 0 && <><h3>Excluded usage</h3><ul>{estimate.exclusions.map(item => <li key={`${item.provider}/${item.modelId}/${item.reason}`}><strong>{providerName(item.provider)} / {item.modelId}</strong><br />{item.reason} ({item.rows} records; {item.tokens ? `${item.tokens.total.toLocaleString()} recorded tokens` : 'token quantity unknown'})</li>)}</ul></>}
      <dl>
      <dt>Retained records</dt><dd>{value.rows}</dd>
      {value.tokens && <Components value={value.tokens} />}
      <dt>Rows with cost</dt><dd>{value.recordedCost.rowsWithCost}</dd><dt>Cost missing</dt><dd>{value.recordedCost.missingCostRows}</dd><dt>Ambiguous zero costs</dt><dd>{value.recordedCost.ambiguousZeroRows}</dd>
      <dt>Unpriced rows</dt><dd>{value.estimate.coverage.unpricedRows}</dd><dt>Usage missing</dt><dd>{value.missingUsageRows}</dd>
      <dt>Fully priced rows</dt><dd>{value.estimate.coverage.fullyPricedRows}</dd><dt>Bounded rows</dt><dd>{value.estimate.coverage.boundedRows}</dd><dt>Partially priced rows</dt><dd>{value.estimate.coverage.partiallyPricedRows}</dd>
    </dl><p>Exclusion counts can overlap; row coverage categories are disjoint.</p>
      <details><summary>Priced components</summary><dl><Components value={value.estimate.coverage.pricedComponents} /></dl></details>
      <details><summary>Unpriced known components</summary><dl><Components value={value.estimate.coverage.unpricedComponents} /></dl></details>
    </details></>
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
  return <section className="activity-region" aria-label="Recorded OpenCode activity">
    <div className="activity-heading"><div><h2>OpenCode activity</h2><p>Recorded usage on this Mac, grouped by provider.</p></div>
    <div className="activity-ranges" aria-label="Activity range">{activityRanges.map(item => <button key={item.value} aria-pressed={range === item.value} onClick={() => setRange(item.value)}>{item.label}</button>)}</div>
    </div>
    {error && <p role="alert">{error} Last view is stale.</p>}
    {group?.error && <p role="alert">{group.error.message}</p>}
    <p className="scan-status">{group?.refreshing ? 'Scanning…' : !group || groupIsStale(group) || error ? 'Stale / unavailable' : 'Last scanned'} · {exact(group?.observedAt ?? null)}</p>
    {!data ? <p>Activity unavailable</p> : <>
      {data.range !== range && <p role="status">Showing {activityRanges.find(item => item.value === data.range)?.label?.toLowerCase()} while the requested range loads.</p>}
      <Totals value={data.totals} />
      <div className="trend-panel"><div className="section-heading"><h3>Tokens over 30 days</h3><span>Selected days highlighted</span></div>
      <div className="activity-trend" role="img" aria-label="30-day recorded token trend">
        {data.trend.days.map(day => <div key={day.date} className={day.selected ? 'selected' : ''} style={{ height: `${Math.max(2, (day.totals.tokens?.total ?? 0) / max * 100)}%` }} title={`${day.date}: ${tokenLabel(day.totals)}; ${estimateLabel(day.totals.estimate)}${day.totals.missingUsageRows ? '; usage missing' : ''}`} />)}
      </div>
      <div className="window-heading"><span>{data.trend.days[0]?.date}</span><span>{data.trend.days.at(-1)?.date}</span></div>
      <details><summary>Daily values</summary>{data.trend.days.map(day => <details key={day.date}><summary>{day.date}{day.selected ? ' (selected)' : ''}: {tokenLabel(day.totals)}</summary><Totals value={day.totals} /></details>)}</details></div>
      <div className="provider-breakdown"><h3>By provider</h3>
      {data.providers.map(provider => <details key={provider.provider}><summary><span>{providerName(provider.provider)}</span><span>{tokenLabel(provider.totals)}</span></summary><Totals value={provider.totals} />{provider.models.map(model => <details key={model.modelId}><summary>{model.modelId}</summary><Totals value={model.totals} /></details>)}</details>)}
      </div>
      <details className="source-details"><summary>Source, pricing, and freshness</summary>
        <p>Partial history · Provider/local-database attribution, not Accounts. Timezone: {data.timezone}.</p>
        <p>Standard/global comparison, not subscription charges, historical bills, quota debit or savings.</p>
        <p>Pricing SHA-256: {data.pricing.digest}</p>
        {data.source.qualifications.map(note => <p key={note}>{note}</p>)}
        <dl><dt>Range start</dt><dd>{exact(data.startAt)}</dd><dt>Exclusive end</dt><dd>{exact(data.endAt)}</dd><dt>First retained</dt><dd>{exact(data.source.firstRetainedAt)}</dd><dt>Last retained</dt><dd>{exact(data.source.lastRetainedAt)}</dd><dt>Populated retained days</dt><dd>{data.source.populatedDays} (not continuous coverage)</dd><dt>Last attempt</dt><dd>{exact(group?.lastAttemptAt ?? null)}</dd><dt>Next scan</dt><dd>{exact(group?.nextAttemptAt ?? null)}</dd><dt>Pricing revision</dt><dd>{data.pricing.revision} ({data.pricing.observedOn})</dd></dl>
      </details>
    </>}
  </section>
}
