import { useEffect, useRef, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { balanceLabel, creditExpiryLabel, resetCountLabel, decodeAccounts, groupIsStale, moneyLabel, overviewWindows, percentage, quotaWarning, type Account, type AccountsResponse, type RefreshResponse, type Fault } from './api'
import './style.css'
import { providerName } from './ProviderLogo'
import { RecordedActivity } from './RecordedActivity'
import { useResetControls } from './ResetControls'
import { QuotaRow } from './QuotaRow'
import { AccountPreferences, ColorPicker, type PreferenceChange } from './AccountPreferences'

function AccountCard({ account, timezone, disconnected, inventoryError, now, save, saving }: { account: Account; timezone: string; disconnected: boolean; inventoryError: Fault | null; now: number; save: (change: PreferenceChange) => Promise<boolean>; saving: boolean }) {
  const quota = account.groups.quotas
  const windows = overviewWindows(account)
  const extra = account.groups.extraUsage
  const extraLabel = account.provider === 'xai' ? 'PAYG' : 'Extra usage'
  const [details, setDetails] = useState(false)
  const resets = useResetControls(account)
  const stale = groupIsStale(quota) || disconnected || windows.some(window => window.stale || (window.resetAt !== null && Date.parse(window.resetAt) <= Date.now()))
  const exact = (date: string | null) => date ? new Date(date).toLocaleString(undefined, { timeZone: timezone }) : 'Unavailable'
  const observed = (date: string | null) => date ? `${exact(date)} (${Math.max(0, Math.floor((Date.now() - Date.parse(date)) / 60_000))}m ago)` : 'Never'
  const shortDate = (date: string) => new Date(date).toLocaleString(undefined, { timeZone: timezone, dateStyle: 'medium', timeStyle: 'short' })
  const warning = quotaWarning(account, disconnected, inventoryError, now)
  const errors = [...new Set(Object.values(account.groups).flatMap(group => group.error ? [group.error.message] : []))]
  return <article className="account">
    <header className="account-heading">
      <ColorPicker account={account} save={save} disabled={saving || disconnected} />
      <div><h2>{providerName(account.provider)}</h2><p><span className="account-alias">{account.name}</span><span>{account.groups.plan.data?.name ?? 'Plan unknown'}</span></p></div>
      {stale && <span className="quota-warning" tabIndex={0} aria-label={warning || 'Stale reading'} title={warning || 'Last-good values may be out of date'}><svg width="16" height="16" viewBox="0 0 20 20" aria-hidden="true"><path d="M10 2 19 18H1Z M10 7v5 M10 14v1" fill="none" stroke="currentColor" strokeWidth="1.5" /></svg><span role="tooltip">{warning || 'Last-good values may be out of date'}</span></span>}
      {resets.warning}
      <button className="details-toggle" aria-label={`Details for ${account.name}`} aria-expanded={details} onClick={() => setDetails(!details)}><span className="card-chevron" aria-hidden="true">⌃</span></button>
    </header>
    {resets.result}
    {windows.length === 0 && <div className="unavailable"><strong>?</strong><div className="bar uncertain" /><p>{quota.observedAt ? 'No quota windows reported' : 'Quota unavailable'}</p></div>}
    {windows.map(window => <QuotaRow key={window.id} window={window} stale={disconnected || groupIsStale(quota, now)} now={now} />)}
    {(account.provider === 'anthropic' || account.provider === 'xai') && <section className="quota" aria-label={account.provider === 'xai' ? 'PAYG' : 'Extra usage'}>
      <div className="window-heading"><span>{account.provider === 'xai' ? 'PAYG' : 'Extra usage'}</span><strong>{extra.data?.presentation === 'off' ? 'Off' : extra.data?.presentation === 'bounded' ? `${moneyLabel(extra.data.remaining)} remaining` : extra.data?.presentation === 'used_only' ? `${moneyLabel(extra.data.used)} used` : 'Unavailable'}</strong></div>
      {extra.data?.presentation === 'bounded' && <>
        <div className="bar" aria-label={`${percentage(extra.data.remainingPercent)} remaining`}><div style={{ width: `${extra.data.remainingPercent}%` }} /></div>
        <p className="timing">{moneyLabel(extra.data.used)} used of {moneyLabel(extra.data.limit)}</p>
      </>}
      {(disconnected || groupIsStale(extra)) && <p className="timing">{extraLabel} stale</p>}
    </section>}
    {account.provider === 'openai' && <>
      <section className="quota" aria-label="Purchased credits">
        <div className="window-heading"><span>Purchased credits</span><strong>{account.groups.balances.data?.items.map(balanceLabel).join(', ') ?? 'Unavailable'}</strong></div>
        {(disconnected || groupIsStale(account.groups.balances)) && <p className="timing">Purchased credits stale</p>}
      </section>
      <details className="reset-credits"><summary>{resetCountLabel(account.groups.resetSummary.data)}{(disconnected || groupIsStale(account.groups.resetSummary)) && ' (stale)'}</summary>
        {account.groups.resetDetails.data === null ? <p>Credit list unavailable</p> : account.groups.resetDetails.data.credits.length === 0 ? <p>No reset credits reported</p> : account.groups.resetDetails.data.credits.map(credit => <section className="credit" key={credit.id}>
          <div className="credit-heading"><h3>{credit.title ?? 'Reset credit'}</h3><p>{credit.expiry.kind === 'at' ? `Expires ${new Date(credit.expiry.at).toLocaleDateString(undefined, { timeZone: timezone, dateStyle: 'medium' })}` : creditExpiryLabel(credit, timezone)}</p></div>
          <div className="credit-action">{resets.action(credit)}</div>
          <details><summary>Details</summary><dl>
            <dt>Credit ID</dt><dd>{credit.id}</dd><dt>Type</dt><dd>{credit.type ?? 'Unknown'}</dd>
            <dt>Status</dt><dd>{credit.status ?? 'Unknown'}</dd><dt>Available</dt><dd>{credit.available === null ? 'Unknown' : credit.available ? 'Yes' : 'No'}</dd>
            <dt>Granted</dt><dd>{exact(credit.grantedAt)}</dd><dt>Expiry</dt><dd>{creditExpiryLabel(credit, timezone)}</dd>
            {credit.description && <><dt>Description</dt><dd>{credit.description}</dd></>}
          </dl></details>
        </section>)}
        <p className="fine-print">Using a credit requires confirmation. OpenAI decides which windows reset.</p>
      </details>
    </>}
    {details && <section className="details" aria-label={`Details for ${account.name}`}>
      {errors.map(error => <p className="account-error" role="alert" key={error}>{error}</p>)}
      {windows.filter(window => window.resetAt || window.pacing).map(window => <section className="quota-detail" key={window.id}><h3>{window.label}</h3><dl>
        {window.resetAt && <><dt>Resets</dt><dd>{shortDate(window.resetAt)}</dd></>}
        {!disconnected && !groupIsStale(quota, now) && !window.stale && window.resetAt && Date.parse(window.resetAt) > now && window.pacing && <><dt>At current pace</dt><dd>{window.pacing.runOutAt ? `Runs out ${shortDate(window.pacing.runOutAt)}` : 'Lasts through reset'}</dd></>}
      </dl></section>)}
      {windows.some(window => window.pacing) && <p className="fine-print">Pacing estimates assume your average usage rate continues.</p>}
      <details><summary>Technical details</summary><dl>
      {account.command.state && <><dt>Reset operation</dt><dd>{account.command.state === 'unknown' ? 'Outcome unknown; open the card-header warning to acknowledge.' : 'Redeeming…'} {account.command.blockingOperationId}</dd></>}
      <dt>Mac timezone</dt><dd>{timezone}</dd>
      {(['plan', 'quotas', 'extraUsage', 'balances', 'resetSummary', 'resetDetails'] as const).map(key => {
        const group = account.groups[key]
        const label = { plan: 'Plan', quotas: 'Quotas', extraUsage: extraLabel, balances: 'Purchased credits', resetSummary: 'Reset count', resetDetails: 'Reset details' }[key]
        return <div className="detail-window" key={key}>
          <dt>{label} observed</dt><dd>{observed(group.observedAt)}</dd>
          <dt>{label} attempt</dt><dd>{exact(group.lastAttemptAt)}</dd>
          <dt>{label} collection</dt><dd>{group.refreshing ? 'Refreshing' : disconnected || groupIsStale(group) ? 'Stale' : group.data === null ? 'Not applicable / absent' : 'Current'}</dd>
          <dt>{label} next</dt><dd>{group.nextAttemptAt ? exact(group.nextAttemptAt) : 'Not scheduled'}</dd>
          {group.error && <><dt>{label} error</dt><dd>{group.error.message}</dd></>}
        </div>
      })}
      {account.provider === 'openai' && <><dt>Available resets</dt><dd>{account.groups.resetSummary.data?.availableCount ?? 'Unavailable'}</dd><dt>Provider-applicable</dt><dd>{account.groups.resetSummary.data?.applicableAvailableCount ?? 'Not reported'}</dd><dt>Count source</dt><dd>{account.groups.resetSummary.data?.source ?? 'Unavailable'}</dd><dt>Credit comparison</dt><dd>USD 0.04 per purchased credit; not provider-reported cash.</dd></>}
      {extra.data?.used && <><dt>{extraLabel} source</dt><dd>{`${extra.data.used.source.amount} ${extra.data.used.source.unit}; exponent ${extra.data.used.source.exponent ?? 'unknown'}`}</dd></>}
      {windows.map(window => <div className="detail-window" key={window.id}>
        <dt>{window.label} scope</dt><dd>{window.scopeNote ?? window.scope}</dd>
        <dt>{window.label} used</dt><dd>{window.usedPercent === null ? '?' : `${window.usedPercent}%`}</dd>
        <dt>Exact reset</dt><dd>{exact(window.resetAt)}</dd>
        <dt>Pacing</dt><dd>{window.pacing ? `${Math.round(window.pacing.projectedUsedPercent)}% projected at reset` : window.pacingUnavailableReason}</dd>
        {window.pacing && <><dt>Spare allowance</dt><dd>{window.pacing.sparePercent.toFixed(1)}%</dd><dt>Average-rate run-out</dt><dd>{window.pacing.runOutAt ? exact(window.pacing.runOutAt) : window.pacing.runOutReason}</dd></>}
      </div>)}
    </dl></details></section>}
  </article>
}

function App() {
  const [data, setData] = useState<AccountsResponse>()
  const [error, setError] = useState<string>()
  const [refreshing, setRefreshing] = useState(false)
  const [view, setView] = useState<'accounts' | 'activity'>('accounts')
  const [settingsOpen, setSettingsOpen] = useState(false)
  const [saving, setSaving] = useState(false)
  const [preferenceError, setPreferenceError] = useState<string>()
  const [schedule, setSchedule] = useState<RefreshResponse>()
  const [activityObserved, setActivityObserved] = useState<string | null>(null)
  const [now, setNow] = useState(Date.now())
  const build = useRef<string>(undefined)
  const refreshDialog = useRef<HTMLDialogElement>(null)
  useEffect(() => {
    let stopped = false
    let inFlight = false
    const controller = new AbortController()
    async function poll() {
      if (document.hidden || inFlight) return
      inFlight = true
      try {
        const response = await fetch('/api/v1/accounts', { cache: 'no-store', signal: AbortSignal.any([controller.signal, AbortSignal.timeout(10_000)]) })
        if (!response.ok) throw new Error(`Tally connection failed (HTTP ${response.status}).`)
        const next = decodeAccounts(await response.text())
        if (build.current && build.current !== next.status.appBuild) { location.reload(); return }
        build.current = next.status.appBuild
        if (!stopped) { setData(next); setError(undefined) }
      } catch (failure) { if (!stopped) setError(failure instanceof Error ? failure.message : 'Tally connection failed.') }
      finally { inFlight = false }
    }
    void poll()
    const interval = setInterval(() => { setNow(Date.now()); void poll() }, 15_000)
    const visible = () => { if (!document.hidden) { setNow(Date.now()); void poll() } }
    document.addEventListener('visibilitychange', visible)
    window.addEventListener('tally:operation', visible)
    window.addEventListener('online', visible)
    return () => { stopped = true; controller.abort(); clearInterval(interval); document.removeEventListener('visibilitychange', visible); window.removeEventListener('tally:operation', visible); window.removeEventListener('online', visible) }
  }, [])
  async function refresh() {
    setRefreshing(true)
    try {
      const response = await fetch('/api/v1/refresh', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' })
      if (!response.ok) throw new Error('Refresh could not be scheduled. Check Tally on your Mac.')
      const result: RefreshResponse = await response.json()
      setSchedule(result)
      const current = await fetch('/api/v1/accounts', { cache: 'no-store', signal: AbortSignal.timeout(10_000) })
      if (!current.ok) throw new Error('Refresh was scheduled, but updated state could not be read.')
      const next = decodeAccounts(await current.text())
      if (build.current && build.current !== next.status.appBuild) { location.reload(); return }
      build.current = next.status.appBuild
      setData(next)
      setError(undefined)
    } catch (failure) { setError(failure instanceof Error ? failure.message : 'Refresh failed.') }
    finally { setRefreshing(false) }
  }
  async function savePreference(change: PreferenceChange): Promise<boolean> {
    setSaving(true)
    setPreferenceError(undefined)
    try {
      const url = change.kind === 'color' ? `/api/v1/accounts/${encodeURIComponent(change.accountId)}/color` : `/api/v1/${change.kind}`
      const body = change.kind === 'color' ? { index: change.index } : { accountIds: change.accountIds }
      const response = await fetch(url, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), signal: AbortSignal.timeout(10_000) })
      if (!response.ok) { const result: { error: Fault } = await response.json(); throw new Error(result.error.message) }
      const next = decodeAccounts(await response.text())
      if (build.current && build.current !== next.status.appBuild) { location.reload(); return true }
      setData(next)
      window.dispatchEvent(new Event('tally:operation'))
      return true
    } catch (failure) {
      setPreferenceError(failure instanceof Error ? failure.message : 'Preferences could not be saved.')
      return false
    } finally { setSaving(false) }
  }
  const latest = [...data?.accounts.flatMap(account => Object.values(account.groups).map(group => group.observedAt)) ?? [], activityObserved].filter(date => date !== null).sort().at(-1)
  return <main>
    <header className="page-heading"><div className="brand"><h1>Tally</h1><span>Subscription usage</span></div><div className="refresh-controls"><p>{latest ? now - Date.parse(latest) < 60_000 ? 'Updated just now' : `Updated ${Math.max(0, Math.floor((now - Date.parse(latest)) / 60_000))}m ago` : 'No successful reading yet'}</p><button disabled={refreshing} onClick={() => refreshDialog.current?.showModal()}>{refreshing ? 'Refreshing…' : 'Refresh'}</button></div></header>
    <nav className="view-switcher" aria-label="Dashboard view"><button aria-pressed={view === 'accounts'} onClick={() => setView('accounts')}>Accounts{data && <span>{data.accounts.length}</span>}</button><button aria-pressed={view === 'activity'} onClick={() => setView('activity')}>Activity</button><button className="settings-button" disabled={!data} onClick={() => setSettingsOpen(true)}>Settings</button></nav>
    {preferenceError && <p className="notice" role="alert">{preferenceError}</p>}
    {error && <p className="notice" role="alert">{error} Displayed readings may be stale.</p>}
    {data?.status.inventory.error && <p className="notice" role="alert">{data.status.inventory.error.message}</p>}
    <div className="account-region" hidden={view !== 'accounts'}>
    {[true, false].map(pinned => data?.accounts.some(account => account.pinned === pinned) && <section key={String(pinned)}>
      {pinned && <div className="section-heading"><h2>Pinned</h2><span>{data.accounts.filter(account => account.pinned).length} accounts</span></div>}
      <div className="accounts">{data.accounts.filter(account => account.pinned === pinned).map(account => <AccountCard key={account.id} account={account} timezone={data.status.timezone} disconnected={!!error} inventoryError={data.status.inventory.error} now={now} save={savePreference} saving={saving} />)}</div>
    </section>)}
    {data?.accounts.length === 0 && <p>No supported Accounts available. Manage Accounts and authentication in OpenCode, or check the database path in Tally settings on your Mac.</p>}
    {!data && !error && <p>Reading Tally…</p>}
    </div><div hidden={view !== 'activity'}><RecordedActivity refresh={schedule} onObserved={setActivityObserved} /></div>
    <AccountPreferences accounts={data?.accounts ?? []} open={settingsOpen} close={() => setSettingsOpen(false)} save={savePreference} disabled={saving || !!error} error={preferenceError} />
    <dialog ref={refreshDialog} className="refresh-dialog" aria-labelledby="refresh-title" onClick={event => { if (event.target === event.currentTarget) refreshDialog.current?.close() }}>
      <form method="dialog" onSubmit={event => { event.preventDefault(); refreshDialog.current?.close(); void refresh() }}>
        <h2 id="refresh-title">Refresh provider usage?</h2>
        <p>This requests up-to-date usage from your providers before the next scheduled check. Provider cooldowns still apply.</p>
        <p className="fine-print">Reloading the page or pulling down to refresh only reloads Tally's saved readings.</p>
        <div><button type="button" autoFocus onClick={() => refreshDialog.current?.close()}>Cancel</button><button type="submit" disabled={refreshing}>Refresh providers</button></div>
      </form>
    </dialog>
  </main>
}

createRoot(document.getElementById('root')!).render(<App />)

if (import.meta.env.PROD && 'serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    void navigator.serviceWorker.register('/sw.js', { updateViaCache: 'none' }).catch(error => {
      console.error('Tally offline support could not be installed.', error)
    })
  })
}
