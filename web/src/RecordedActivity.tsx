import { useEffect, useRef, useState, type PointerEvent } from 'react'
import { groupIsStale, moneyLabel, type Account } from './api'
import { activityRanges, apiValue, compactTokens, decodeActivity, tokenLabel, usd, type ActivityData, type ActivityRange, type ActivityResponse } from './activity'
import { ProviderLogo, providerName } from './ProviderLogo'
import { TallyMeter } from './QuotaRow'
import { Collapse, Segmented, Swap } from './motion'

const dayLabel = (date: string, options: Intl.DateTimeFormatOptions = { month: 'short', day: 'numeric' }) => new Date(`${date}T12:00:00Z`).toLocaleDateString(undefined, { ...options, timeZone: 'UTC' })

// Provider-reported money charged beyond a plan. Local token history cannot tell which requests were billed this way.
function ExtraUsageBilled({ accounts, disconnected }: { accounts: Account[]; disconnected: boolean }) {
  const billed = accounts.filter(account => (account.provider === 'anthropic' || account.provider === 'xai') && account.groups.extraUsage.data && account.groups.extraUsage.data.presentation !== 'unavailable')
  // Providers report in their own units (xAI PAYG is credits), so each currency totals separately rather than hiding behind a dollar figure.
  const totals = new Map<string, number>([['USD', 0]])
  for (const account of billed) {
    const used = account.groups.extraUsage.data?.used
    if (used) totals.set(used.currency, (totals.get(used.currency) ?? 0) + Number(used.amount))
  }
  const headline = [...totals].filter(([currency, amount]) => currency === 'USD' || amount > 0)
    .map(([currency, amount]) => currency === 'USD' ? usd(String(amount)) : `${amount.toLocaleString()} ${currency}`).join(' + ')
  return <section className="activity-panel" aria-labelledby="extra-billed-title">
    <header className="panel-head">
      <div><h2 id="extra-billed-title">Extra usage billed</h2><p className="muted">Real charges beyond your plans, this billing period, as reported by each provider.</p></div>
      <Swap className="stat-value" value={headline} />
    </header>
    {billed.length === 0 ? <p className="muted">No account reports extra usage.</p> : <ul className="billed">{billed.map(account => {
      const extra = account.groups.extraUsage.data!
      return <li key={account.id}>
        <ProviderLogo provider={account.provider} color={account.identityColorIndex} />
        <span><strong>{account.name}</strong><span className="muted">{providerName(account.provider)} {account.provider === 'xai' ? 'PAYG' : 'extra usage'}{(disconnected || groupIsStale(account.groups.extraUsage)) && ', out of date'}</span></span>
        <span className="billed-amount">{extra.presentation === 'off' && (extra.used === null || Number(extra.used.amount) === 0) ? <span className="muted">Off</span> : <>{moneyLabel(extra.used)}{extra.limit && extra.presentation === 'bounded' && <span className="muted"> of {moneyLabel(extra.limit)}</span>}</>}</span>
      </li>
    })}</ul>}
  </section>
}

function ProviderRow({ provider, total }: { provider: ActivityData['providers'][number]; total: number }) {
  const [open, setOpen] = useState(false)
  return <div className="provider" data-open={open}>
    <button className="provider-summary" aria-expanded={open} onClick={() => setOpen(!open)}>
      <ProviderLogo provider={provider.provider} color={0} />
      <span className="provider-name">{providerName(provider.provider)}</span>
      <TallyMeter percent={total ? (provider.totals.tokens?.total ?? 0) / total * 100 : 0} label={`${providerName(provider.provider)} share of tokens`} />
      <span className="provider-tokens">{tokenLabel(provider.totals)}</span>
      <span className="provider-price">{apiValue(provider.totals)}</span>
    </button>
    <Collapse open={open}><ul className="models">{provider.models.map(model => <li key={model.modelId}><span>{model.modelId}</span><span>{tokenLabel(model.totals)}</span><span className={model.totals.estimate.lower === null ? 'muted' : undefined}>{apiValue(model.totals)}</span></li>)}</ul></Collapse>
  </div>
}

export function RecordedActivity({ refresh, onObserved, accounts, disconnected }: { refresh: unknown; onObserved: (date: string | null) => void; accounts: Account[]; disconnected: boolean }) {
  const [range, setRange] = useState<ActivityRange>('today')
  const [response, setResponse] = useState<ActivityResponse>()
  const [error, setError] = useState<string>()
  const [pointed, setPointed] = useState<number>()
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
  const days = data?.trend.days ?? []
  const max = Math.max(1, ...days.map(day => day.totals.tokens?.total ?? 0))
  const total = data?.totals.tokens?.total ?? 0
  const focus = pointed === undefined ? undefined : days[pointed]
  const scanned = group?.observedAt ? Math.max(0, Math.floor((Date.now() - Date.parse(group.observedAt)) / 60_000)) : null
  function point(event: PointerEvent<HTMLDivElement>) {
    const box = event.currentTarget.getBoundingClientRect()
    setPointed(Math.min(days.length - 1, Math.max(0, Math.floor((event.clientX - box.left) / box.width * days.length))))
  }
  const value = data ? apiValue(data.totals) : null
  return <section className="activity" aria-label="Recorded OpenCode activity">
    {error && <p className="notice" role="alert">{error} Showing the last reading.</p>}
    {group?.error && <p className="notice" role="alert">{group.error.message}</p>}
    <section className="activity-panel" aria-labelledby="plan-usage-title">
      <header className="panel-head">
        <div><h2 id="plan-usage-title">Token usage</h2><p className="muted">Tokens OpenCode recorded on this Mac, and what they would cost at pay-as-you-go API prices.</p></div>
        <Segmented label="Activity range" value={range} onChange={setRange} options={activityRanges} />
      </header>
      {!data ? <p className="loading">{group ? 'Activity unavailable' : 'Reading activity…'}</p> : <>
        <div className="stats">
          <div><span className="muted">Tokens</span><Swap className="stat-value" title={data.totals.tokens ? `${data.totals.tokens.total.toLocaleString()} tokens` : undefined} value={data.totals.rows === 0 ? '0' : data.totals.tokens ? compactTokens(data.totals.tokens.total) : 'Unknown'} /></div>
          <div><span className="muted">API equivalent</span><Swap className="stat-value" value={value ?? '$0'} /></div>
        </div>
        {(data.totals.estimate.status === 'partial' || data.totals.missingUsageRows > 0) && <p className="fine-print">
          {data.totals.estimate.status === 'partial' && 'Some models have no listed API price, so the equivalent is a floor. '}
          {data.totals.missingUsageRows > 0 && `${data.totals.missingUsageRows.toLocaleString()} records have no usage recorded.`}
        </p>}
        {data.providers.length > 0 && <div className="providers">{data.providers.map(provider => <ProviderRow key={provider.provider} provider={provider} total={total} />)}</div>}
      </>}
    </section>
    {data && <section className="activity-panel" aria-labelledby="daily-title">
      <header className="panel-head">
        <div><h2 id="daily-title">Daily tokens</h2><p className="muted">Last 30 days. The selected range is highlighted; select a day to see its total.</p></div>
      </header>
      <p className="trend-caption" aria-live="polite">{focus
        ? <><strong>{dayLabel(focus.date, { weekday: 'short', month: 'short', day: 'numeric' })}</strong> <span>{tokenLabel(focus.totals)}</span>{apiValue(focus.totals) && <span className="muted">API equivalent {apiValue(focus.totals)}</span>}</>
        : <span className="muted">{compactTokens(days.reduce((sum, day) => sum + (day.totals.tokens?.total ?? 0), 0))} tokens across 30 days</span>}</p>
      <div className="trend-strokes" role="img" aria-label={`Daily recorded tokens, ${dayLabel(days[0]?.date ?? '')} to ${dayLabel(days.at(-1)?.date ?? '')}`}
        onPointerMove={point} onPointerDown={point} onPointerLeave={event => { if (event.pointerType === 'mouse') setPointed(undefined) }}>
        {days.map((day, index) => <span key={day.date} data-selected={day.selected} data-pointed={index === pointed} style={{ height: `${Math.max(3, (day.totals.tokens?.total ?? 0) / max * 100)}%` }} />)}
      </div>
      <div className="trend-axis"><span>{days[0] && dayLabel(days[0].date)}</span><span>{days.at(-1) && dayLabel(days.at(-1)!.date)}</span></div>
    </section>}
    <ExtraUsageBilled accounts={accounts} disconnected={disconnected} />
    <p className="fine-print activity-fine-print">
      {group?.refreshing ? 'Scanning OpenCode history… ' : !group || groupIsStale(group) || error ? 'Activity is out of date. ' : scanned === 0 ? 'Scanned just now. ' : `Scanned ${scanned} min ago. `}
      Tokens come from this Mac's OpenCode history, grouped by provider rather than account.{data && (data.pricing.basis === 'models_dev_catalog' ? ` API prices come from models.dev, as of ${data.pricing.observedOn}.` : ` API prices are Tally's built-in reference rates from ${data.pricing.observedOn}.`)}
    </p>
  </section>
}
