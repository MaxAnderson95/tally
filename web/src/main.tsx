import { useEffect, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { balanceLabel, creditExpiryLabel, resetCountLabel, decodeAccounts, groupIsStale, moneyLabel, overviewWindows, percentage, resetLabel, scheduleLabel, type Account, type AccountsResponse, type RefreshResponse } from './api'
import './style.css'

function AccountCard({ account, timezone, disconnected }: { account: Account; timezone: string; disconnected: boolean }) {
  const quota = account.groups.quotas
  const windows = overviewWindows(account)
  const extra = account.groups.extraUsage
  const stale = groupIsStale(quota) || disconnected || windows.some(window => window.stale || (window.resetAt !== null && Date.parse(window.resetAt) <= Date.now()))
  const exact = (date: string | null) => date ? new Date(date).toLocaleString(undefined, { timeZone: timezone }) : 'Unavailable'
  return <article className="account">
    <header className="account-heading">
      {account.provider === 'opencode-go' ? <svg className="logo" viewBox="0 0 24 24" aria-label="OpenCode Go" role="img"><path fill="currentColor" fillRule="evenodd" d="M3 3h18v18H3V3zm4 4v10h10V7H7zm6 2h2v6h-2V9z" /></svg> : <span>{account.provider}</span>}
      <div><h2>{account.name}</h2><p>{account.groups.plan.data?.name ?? 'Plan unknown'}</p></div>
      {stale && <svg width="16" height="16" viewBox="0 0 20 20" role="img" aria-label="Stale reading"><title>Last-good values may be out of date</title><path d="M10 2 19 18H1Z M10 7v5 M10 14v1" fill="none" stroke="currentColor" strokeWidth="1.5" /></svg>}
    </header>
    {windows.length === 0 && <div className="unavailable"><strong>?</strong><p>{quota.observedAt ? 'No quota windows reported' : 'Quota unavailable'}</p></div>}
    {windows.map((window, index) => <section className="quota" key={window.id}>
      <div className={index === 0 && window.durationSeconds !== null ? 'hero' : 'window-heading'}>
        {index === 0 && window.durationSeconds !== null ? <><strong>{percentage(window.remainingPercent)}</strong><span>{window.label} remaining</span></> : <><span>{window.label}</span><strong>{percentage(window.remainingPercent)}</strong></>}
      </div>
      <div className={`bar ${window.durationSeconds === null || window.remainingPercent === null ? 'uncertain' : ''}`} aria-label={`${percentage(window.remainingPercent)} remaining`}>
        {window.remainingPercent !== null && <div style={{ width: `${window.remainingPercent}%` }} />}
      </div>
      <p className="timing">{resetLabel(window)}{window.durationSeconds === null && ' · duration unknown'}</p>
    </section>)}
    {(account.provider === 'anthropic' || account.provider === 'xai') && <section className="quota" aria-label={account.provider === 'xai' ? 'PAYG' : 'Extra usage'}>
      <div className="window-heading"><span>{account.provider === 'xai' ? 'PAYG' : 'Extra usage'}</span><strong>{extra.data?.presentation === 'off' ? 'Off' : extra.data?.presentation === 'bounded' ? `${moneyLabel(extra.data.remaining)} remaining` : extra.data?.presentation === 'used_only' ? `${moneyLabel(extra.data.used)} used` : 'Unavailable'}</strong></div>
      {extra.data?.presentation === 'bounded' && <>
        <div className="bar" aria-label={`${percentage(extra.data.remainingPercent)} remaining`}><div style={{ width: `${extra.data.remainingPercent}%` }} /></div>
        <p className="timing">{moneyLabel(extra.data.used)} used of {moneyLabel(extra.data.limit)}</p>
      </>}
      {(disconnected || groupIsStale(extra)) && <p className="timing">Extra usage stale</p>}
    </section>}
    {account.provider === 'openai' && <>
      <section className="quota" aria-label="Purchased credits">
        <div className="window-heading"><span>Purchased credits</span><strong>{account.groups.balances.data?.items.map(balanceLabel).join(', ') ?? 'Unavailable'}</strong></div>
        {(disconnected || groupIsStale(account.groups.balances)) && <p className="timing">Purchased credits stale</p>}
      </section>
      <details className="reset-credits"><summary>{resetCountLabel(account.groups.resetSummary.data)}{(disconnected || groupIsStale(account.groups.resetSummary)) && ' (stale)'}</summary>
        <p>Reset credits for {account.name}</p>
        <p>Redeeming consumes one credit; the provider decides which windows reset.</p>
        <dl>
          <dt>Available</dt><dd>{account.groups.resetSummary.data?.availableCount ?? 'Unavailable'}</dd>
          <dt>Provider-applicable</dt><dd>{account.groups.resetSummary.data?.applicableAvailableCount ?? 'Not reported'}</dd>
          <dt>Count source</dt><dd>{account.groups.resetSummary.data?.source ?? 'Unavailable'}</dd>
          <dt>Timezone</dt><dd>{timezone}</dd>
          {(['resetSummary', 'resetDetails', 'balances'] as const).map(key => {
            const group = account.groups[key]
            const label = { resetSummary: 'Count', resetDetails: 'Credit list', balances: 'Purchased credits' }[key]
            return <div className="detail-window" key={key}>
              <dt>{label} observed</dt><dd>{exact(group.observedAt)}</dd>
              <dt>{label} attempt</dt><dd>{exact(group.lastAttemptAt)}</dd>
              <dt>{label} collection</dt><dd>{group.refreshing ? 'Refreshing' : disconnected || groupIsStale(group) ? 'Stale' : 'Current'}</dd>
              <dt>{label} next</dt><dd>{exact(group.nextAttemptAt)}</dd>
              {group.error && <><dt>{label} error</dt><dd>{group.error.message}</dd></>}
            </div>
          })}
        </dl>
        <p>Dollar comparisons use a reference rate of USD 0.04 per purchased credit, not provider-reported cash.</p>
        {account.groups.resetDetails.data === null ? <p>Credit list unavailable</p> : account.groups.resetDetails.data.credits.length === 0 ? <p>No reset credits reported</p> : account.groups.resetDetails.data.credits.map(credit => <section key={credit.id}>
          <h3>{credit.title ?? 'Reset credit'}</h3><dl>
            <dt>Credit ID</dt><dd>{credit.id}</dd><dt>Type</dt><dd>{credit.type ?? 'Unknown'}</dd>
            <dt>Status</dt><dd>{credit.status ?? 'Unknown'}</dd><dt>Available</dt><dd>{credit.available === null ? 'Unknown' : credit.available ? 'Yes' : 'No'}</dd>
            <dt>Granted</dt><dd>{exact(credit.grantedAt)}</dd><dt>Expiry</dt><dd>{creditExpiryLabel(credit, timezone)}</dd>
            {credit.description && <><dt>Description</dt><dd>{credit.description}</dd></>}
          </dl>
        </section>)}
      </details>
    </>}
    <details><summary>Details</summary><dl>
      <dt>Observed</dt><dd>{exact(quota.observedAt)}</dd>
      <dt>Last attempt</dt><dd>{exact(quota.lastAttemptAt)}</dd>
      <dt>Collection</dt><dd>{quota.refreshing ? 'Refreshing' : stale ? 'Stale' : 'Current'}</dd>
      <dt>Next attempt</dt><dd>{quota.nextAttemptAt ? exact(quota.nextAttemptAt) : 'Not scheduled'}</dd>
      <dt>Timezone</dt><dd>{timezone}</dd>
      {quota.error && <><dt>Error</dt><dd>{quota.error.message}</dd></>}
      {(account.provider === 'anthropic' || account.provider === 'xai') && <>
        <dt>Plan observed</dt><dd>{exact(account.groups.plan.observedAt)}</dd>
        <dt>Plan collection</dt><dd>{account.groups.plan.refreshing ? 'Refreshing' : groupIsStale(account.groups.plan) ? 'Stale' : 'Current'}</dd>
        {account.groups.plan.error && <><dt>Plan error</dt><dd>{account.groups.plan.error.message}</dd></>}
        <dt>Extra usage observed</dt><dd>{exact(extra.observedAt)}</dd>
        <dt>Extra usage attempt</dt><dd>{exact(extra.lastAttemptAt)}</dd>
        <dt>Extra usage next</dt><dd>{exact(extra.nextAttemptAt)}</dd>
        <dt>Extra usage collection</dt><dd>{extra.refreshing ? 'Refreshing' : disconnected || groupIsStale(extra) ? 'Stale' : 'Current'}</dd>
        {extra.error && <><dt>Extra usage error</dt><dd>{extra.error.message}</dd></>}
        <dt>Extra usage source</dt><dd>{extra.data?.used ? `${extra.data.used.source.amount} ${extra.data.used.source.unit}; exponent ${extra.data.used.source.exponent ?? 'unknown'}` : 'Unavailable'}</dd>
      </>}
      {windows.map(window => <div className="detail-window" key={window.id}>
        <dt>{window.label} scope</dt><dd>{window.scopeNote ?? window.scope}</dd>
        <dt>{window.label} used</dt><dd>{percentage(window.usedPercent)}</dd>
        <dt>Exact reset</dt><dd>{exact(window.resetAt)}</dd>
        <dt>Pacing</dt><dd>{window.pacing ? `${Math.round(window.pacing.projectedUsedPercent)}% projected at reset` : window.pacingUnavailableReason}</dd>
      </div>)}
    </dl></details>
  </article>
}

function App() {
  const [data, setData] = useState<AccountsResponse>()
  const [error, setError] = useState<string>()
  const [refreshing, setRefreshing] = useState(false)
  const [schedule, setSchedule] = useState<RefreshResponse>()
  const [now, setNow] = useState(Date.now())
  useEffect(() => {
    let stopped = false
    let inFlight = false
    let build: string | undefined
    const controller = new AbortController()
    async function poll() {
      if (document.hidden || inFlight) return
      inFlight = true
      try {
        const response = await fetch('/api/v1/accounts', { signal: controller.signal })
        if (!response.ok) throw new Error(`Tally connection failed (HTTP ${response.status}).`)
        const next = decodeAccounts(await response.text())
        if (build && build !== next.status.appBuild) { location.reload(); return }
        build = next.status.appBuild
        if (!stopped) { setData(next); setError(undefined) }
      } catch (failure) { if (!stopped) setError(failure instanceof Error ? failure.message : 'Tally connection failed.') }
      finally { inFlight = false }
    }
    void poll()
    const interval = setInterval(() => { setNow(Date.now()); void poll() }, 15_000)
    const visible = () => { if (!document.hidden) { setNow(Date.now()); void poll() } }
    document.addEventListener('visibilitychange', visible)
    return () => { stopped = true; controller.abort(); clearInterval(interval); document.removeEventListener('visibilitychange', visible) }
  }, [])
  async function refresh() {
    setRefreshing(true)
    try {
      const response = await fetch('/api/v1/refresh', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' })
      if (!response.ok) throw new Error('Refresh could not be scheduled. Check Tally on your Mac.')
      const result: RefreshResponse = await response.json()
      setSchedule(result)
      const current = await fetch('/api/v1/accounts')
      if (!current.ok) throw new Error('Refresh was scheduled, but updated state could not be read.')
      setData(decodeAccounts(await current.text()))
      setError(undefined)
    } catch (failure) { setError(failure instanceof Error ? failure.message : 'Refresh failed.') }
    finally { setRefreshing(false) }
  }
  const latest = data?.accounts.map(account => account.groups.quotas.observedAt).filter(date => date !== null).sort().at(-1)
  return <main>
    <header className="page-heading"><div><h1>Tally</h1><p>{latest ? `Updated ${Math.max(0, Math.floor((now - Date.parse(latest)) / 60_000))}m ago` : 'No successful reading yet'}</p></div><button disabled={refreshing} onClick={() => void refresh()}>{refreshing ? 'Scheduling…' : 'Refresh'}</button></header>
    {error && <p className="notice" role="alert">{error} Displayed readings may be stale.</p>}
    {schedule && <div className="notice" role="status">
      <p>Last refresh request</p>
      {schedule.accounts.map(item => <p key={item.accountId}>{data?.accounts.find(account => account.id === item.accountId)?.name ?? 'Account'}: {scheduleLabel(item.schedule)}</p>)}
      <p>Activity: {scheduleLabel(schedule.activity)}</p>
    </div>}
    {data?.status.inventory.error && <p className="notice" role="alert">{data.status.inventory.error.message}</p>}
    {[true, false].map(pinned => data?.accounts.some(account => account.pinned === pinned) && <section key={String(pinned)}>
      <h2>{pinned ? 'Pinned' : 'Other accounts'}</h2>
      <div className="accounts">{data.accounts.filter(account => account.pinned === pinned).map(account => <AccountCard key={account.id} account={account} timezone={data.status.timezone} disconnected={!!error} />)}</div>
    </section>)}
    {data?.accounts.length === 0 && <p>No supported Accounts available. Manage Accounts and authentication in OpenCode, or check the database path in Tally settings on your Mac.</p>}
    {!data && !error && <p>Reading Tally…</p>}
  </main>
}

createRoot(document.getElementById('root')!).render(<App />)
