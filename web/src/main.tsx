import { useEffect, useRef, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { decodeAccounts, displayNow, type AccountsResponse, type RefreshResponse, type Fault } from './api'
import './style.css'
import { RecordedActivity } from './RecordedActivity'
import { AccountRow } from './Accounts'
import { AccountPreferences, type PreferenceChange } from './AccountPreferences'
import { PullToReload } from './PullToReload'
import { Segmented, useDialogMotion } from './motion'
import { useWarmups } from './WarmupPreferences'

function App() {
  const [data, setData] = useState<AccountsResponse>()
  const [error, setError] = useState<string>()
  const [refreshing, setRefreshing] = useState(false)
  const [view, setView] = useState<'accounts' | 'activity'>('accounts')
  const [settingsOpen, setSettingsOpen] = useState(false)
  const [saving, setSaving] = useState(false)
  const [switching, setSwitching] = useState<string>()
  const switchInFlight = useRef(false)
  const [preferenceError, setPreferenceError] = useState<string>()
  const [schedule, setSchedule] = useState<RefreshResponse>()
  const [activityObserved, setActivityObserved] = useState<string | null>(null)
  const [now, setNow] = useState(Date.now())
  const warmups = useWarmups()
  const build = useRef<string>(undefined)
  const refreshDialog = useRef<HTMLDialogElement>(null)
  const closeRefresh = useDialogMotion(refreshDialog)
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
  async function activate(accountId: string) {
    if (switchInFlight.current) return
    switchInFlight.current = true
    setSwitching(accountId)
    setPreferenceError(undefined)
    try {
      const response = await fetch(`/api/v1/accounts/${encodeURIComponent(accountId)}/activate`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}', signal: AbortSignal.timeout(25_000) })
      if (!response.ok) { const result: { error: Fault } = await response.json(); throw new Error(result.error.message) }
      setData(decodeAccounts(await response.text()))
    } catch (failure) {
      setPreferenceError(failure instanceof Error ? failure.message + ' Read the current selection before retrying.' : 'Account switch was not confirmed. Check the current selection before retrying.')
    } finally {
      switchInFlight.current = false
      setSwitching(undefined)
      window.dispatchEvent(new Event('tally:operation'))
    }
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
  const timezone = data?.status.timezone ?? Intl.DateTimeFormat().resolvedOptions().timeZone
  const displayed = data ? displayNow(data.status, now) : now
  const sections = [{ title: 'Pinned', pinned: true }, { title: data?.accounts.some(account => account.pinned) ? 'Other accounts' : 'Accounts', pinned: false }]
  return <main>
    <PullToReload loading={!data && !error} />
    <header className="masthead">
      <h1 className="wordmark"><img src="/favicon.svg" alt="" width="28" height="28" />Tally</h1>
      <Segmented className="tabs" label="Dashboard view" value={view} onChange={setView}
        options={[{ value: 'accounts', label: <>Accounts{data && <span className="count">{data.accounts.length}</span>}</> }, { value: 'activity', label: 'Activity' }] as const} />
      <div className="masthead-actions">
        <p className="updated">{latest ? now - Date.parse(latest) < 60_000 ? 'Updated just now' : `Updated ${Math.max(0, Math.floor((now - Date.parse(latest)) / 60_000))} min ago` : 'No reading yet'}</p>
        <button className="quiet-button icon-text refresh-button" disabled={refreshing} onClick={() => refreshDialog.current?.showModal()}>
          <svg viewBox="0 0 20 20" aria-hidden="true" className={refreshing ? 'spinning' : undefined}><path d="M16 10a6 6 0 1 1-1.8-4.3M16 3.5v3.2h-3.2" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" /></svg>
          <span>{refreshing ? 'Refreshing…' : 'Refresh'}</span>
        </button>
        <button className="quiet-button icon-text" disabled={!data} onClick={() => setSettingsOpen(true)} aria-label="Settings">
          <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M4 6h7M15 6h1M4 14h1M9 14h7" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" /><circle cx="13" cy="6" r="2" fill="none" stroke="currentColor" strokeWidth="1.6" /><circle cx="7" cy="14" r="2" fill="none" stroke="currentColor" strokeWidth="1.6" /></svg>
          <span>Settings</span>
        </button>
      </div>
    </header>
    <div className="notices">
      {preferenceError && <p className="notice" role="alert">{preferenceError}</p>}
      {error && <p className="notice" role="alert">{error} Displayed readings may be stale.</p>}
      {warmups.error && <p className="notice" role="alert">{warmups.error} Warm-up status may be out of date.</p>}
      {data?.status.inventory.error && <p className="notice" role="alert">{data.status.inventory.error.message}</p>}
    </div>
    <div className="account-region view" hidden={view !== 'accounts'}>
      {sections.map(({ title, pinned }) => data?.accounts.some(account => account.pinned === pinned) && <section className="ledger" key={title} aria-label={title}>
        <h2 className="ledger-heading">{title}<span>{data.accounts.filter(account => account.pinned === pinned).length}</span></h2>
        <div className="ledger-rows">{data.accounts.filter(account => account.pinned === pinned).map(account => <AccountRow key={account.id} account={account} timezone={timezone} disconnected={!!error} inventoryError={data.status.inventory.error} now={displayed} save={savePreference} saving={saving} activate={activate} switching={switching} warmupWarning={warmups.readings?.[account.id]?.needsAttention ? warmups.readings[account.id].message : undefined} />)}</div>
      </section>)}
      {data?.accounts.length === 0 && <div className="empty-state"><h2>No accounts yet</h2><p>Sign in to Anthropic, OpenAI, OpenCode Go, or xAI in OpenCode and they appear here. If you already have, check the database path in Tally's settings on your Mac.</p></div>}
      {!data && !error && <p className="loading">Reading Tally…</p>}
    </div>
    <div className="view" hidden={view !== 'activity'}><RecordedActivity refresh={schedule} onObserved={setActivityObserved} accounts={data?.accounts ?? []} disconnected={!!error} /></div>
    <AccountPreferences accounts={data?.accounts ?? []} timezone={timezone} open={settingsOpen} close={() => setSettingsOpen(false)} save={savePreference} disabled={saving || !!error} error={preferenceError} warmups={warmups} />
    <dialog ref={refreshDialog} className="sheet small-sheet" aria-labelledby="refresh-title" onCancel={event => { event.preventDefault(); closeRefresh() }} onClick={event => { if (event.target === event.currentTarget) closeRefresh() }}>
      <form method="dialog" onSubmit={event => { event.preventDefault(); closeRefresh(); void refresh() }}>
        <h2 id="refresh-title">Ask providers for fresh usage?</h2>
        <p>Tally checks every two minutes on its own. This asks now; provider cooldowns still apply.</p>
        <p className="fine-print">Pulling down or reloading the page only rereads Tally's saved readings.</p>
        <div className="sheet-actions"><button type="button" className="quiet-button" autoFocus onClick={() => closeRefresh()}>Cancel</button><button type="submit" className="primary-button" disabled={refreshing}>Refresh providers</button></div>
      </form>
    </dialog>
  </main>
}

document.documentElement.dataset.intro = ''
setTimeout(() => { delete document.documentElement.dataset.intro }, 2000)

createRoot(document.getElementById('root')!).render(<App />)

if (import.meta.env.PROD && 'serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    void navigator.serviceWorker.register('/sw.js', { updateViaCache: 'none' }).catch(error => {
      console.error('Tally offline support could not be installed.', error)
    })
  })
}
