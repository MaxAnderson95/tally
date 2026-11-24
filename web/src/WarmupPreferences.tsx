import { useEffect, useRef, useState } from 'react'
import type { Account, Fault, WarmupModel, WarmupReading } from './api'
import { ProviderLogo, providerName } from './ProviderLogo'
import { Collapse } from './motion'

type Readings = Record<string, WarmupReading>
type WarmupPatch = { enabled?: boolean; model?: string; startTime?: string | null }
type PendingWrite = {
  patch: WarmupPatch
  resolvers: { resolve: () => void; reject: (error: unknown) => void }[]
}
// Model lists outlive the sheet so reopening Settings shows names immediately instead of raw model IDs.
const modelCache = new Map<string, WarmupModel[]>()
const TIME_RE = /^\d{2}:\d{2}$/

async function request<T>(url: string, options: RequestInit = {}): Promise<T> {
  const response = await fetch(url, { cache: 'no-store', ...options })
  if (!response.ok) {
    const body: { error: Fault } = await response.json()
    throw new Error(body.error.message)
  }
  return response.json()
}

function mergePatch(previous: WarmupPatch, next: WarmupPatch): WarmupPatch {
  const merged: WarmupPatch = { ...previous }
  if (next.enabled !== undefined) merged.enabled = next.enabled
  if (next.model !== undefined) merged.model = next.model
  if ('startTime' in next) merged.startTime = next.startTime
  return merged
}

export function useWarmups() {
  const [readings, setReadings] = useState<Readings>()
  const [error, setError] = useState<string>()
  const [saving, setSaving] = useState(false)
  const activeAccounts = useRef(new Set<string>())
  const pendingByAccount = useRef(new Map<string, PendingWrite>())
  const revision = useRef(0)
  useEffect(() => {
    const controller = new AbortController()
    let inFlight = false
    async function poll() {
      if (document.hidden || inFlight || activeAccounts.current.size > 0) return
      inFlight = true
      const started = revision.current
      try {
        const result = await request<Readings>('/api/v1/warmups', { signal: AbortSignal.any([controller.signal, AbortSignal.timeout(10_000)]) })
        if (!controller.signal.aborted && started === revision.current) { setReadings(result); setError(undefined) }
      } catch (failure) {
        if (!controller.signal.aborted && started === revision.current) setError(failure instanceof Error ? failure.message : 'Could not read warm-up settings.')
      } finally { inFlight = false }
    }
    void poll()
    const timer = setInterval(() => void poll(), 15_000)
    const visible = () => { if (!document.hidden) void poll() }
    document.addEventListener('visibilitychange', visible)
    window.addEventListener('online', visible)
    window.addEventListener('tally:operation', visible)
    return () => { controller.abort(); clearInterval(timer); document.removeEventListener('visibilitychange', visible); window.removeEventListener('online', visible); window.removeEventListener('tally:operation', visible) }
  }, [])
  async function drain(accountID: string) {
    activeAccounts.current.add(accountID)
    setSaving(true)
    try {
      while (true) {
        const next = pendingByAccount.current.get(accountID)
        if (!next) break
        pendingByAccount.current.delete(accountID)
        revision.current++
        try {
          const updated = await request<Readings>(`/api/v1/accounts/${encodeURIComponent(accountID)}/warmup`, {
            method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(next.patch), signal: AbortSignal.timeout(10_000),
          })
          setReadings(updated)
          setError(undefined)
          for (const entry of next.resolvers) entry.resolve()
        } catch (failure) {
          for (const entry of next.resolvers) entry.reject(failure)
        } finally {
          revision.current++
        }
      }
    } finally {
      activeAccounts.current.delete(accountID)
      if (activeAccounts.current.size === 0) setSaving(false)
      window.dispatchEvent(new Event('tally:operation'))
    }
  }
  function save(accountID: string, patch: WarmupPatch): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const existing = pendingByAccount.current.get(accountID)
      if (existing) {
        existing.patch = mergePatch(existing.patch, patch)
        existing.resolvers.push({ resolve, reject })
      } else {
        pendingByAccount.current.set(accountID, { patch, resolvers: [{ resolve, reject }] })
      }
      if (!activeAccounts.current.has(accountID)) void drain(accountID)
    })
  }
  return { readings, error, saving, save }
}

export function WarmupPreferences({ accounts, timezone, disabled, warmups }: { accounts: Account[]; timezone: string; disabled: boolean; warmups: ReturnType<typeof useWarmups> }) {
  const { readings, error } = warmups
  return <div className="warmup-preferences">
    <p className="warmup-intro">Start five-hour windows before you sit down to code. Choose a model and optional daily start time for each account you enable.</p>
    {error && <p className="note-warn" role="alert">{error}</p>}
    {!readings && !error && <p role="status">Loading warm-up settings…</p>}
    {['anthropic', 'openai', 'opencode-go', 'xai'].map(provider => {
      const matches = accounts.filter(account => account.provider === provider)
      return matches.length > 0 && <section className="warmup-provider" key={provider} aria-label={providerName(provider)}>
        <h3><span aria-hidden="true"><ProviderLogo provider={provider} color={0} /></span>{providerName(provider)}</h3>
        <div className="warmup-accounts">{matches.map(account => <WarmupAccount key={account.id} account={account} status={readings?.[account.id]} timezone={timezone} disabled={disabled || !!error}
          save={patch => warmups.save(account.id, patch)} />)}</div>
      </section>
    })}
  </div>
}

function WarmupAccount({ account, status, timezone, disabled, save }: {
  account: Account; status: WarmupReading | undefined; timezone: string; disabled: boolean
  save: (patch: WarmupPatch) => Promise<void>
}) {
  const [models, setModels] = useState<WarmupModel[]>(() => modelCache.get(account.id) ?? [])
  const [selected, setSelected] = useState(status?.model ?? '')
  const [startTime, setStartTime] = useState<string | null>(status?.startTime ?? null)
  const [startTimeDirty, setStartTimeDirty] = useState(false)
  const [enabled, setEnabled] = useState(status?.enabled ?? false)
  const [loading, setLoading] = useState(() => !modelCache.has(account.id))
  const [saving, setSaving] = useState(false)
  const [saveError, setSaveError] = useState<string>()
  const [error, setError] = useState<string>()
  const [attempt, setAttempt] = useState(0)
  const saveRevision = useRef(0)
  useEffect(() => {
    if (status && !saving) {
      setSelected(status.model)
      setEnabled(status.enabled)
      if (!startTimeDirty) setStartTime(status.startTime)
    }
  }, [status?.model, status?.enabled, status?.startTime, saving, startTimeDirty])
  useEffect(() => {
    const controller = new AbortController()
    if (!modelCache.has(account.id)) setLoading(true)
    void request<WarmupModel[]>(`/api/v1/accounts/${encodeURIComponent(account.id)}/warmup/models`, {
      signal: AbortSignal.any([controller.signal, AbortSignal.timeout(20_000)]),
    }).then(result => {
      if (!controller.signal.aborted) { modelCache.set(account.id, result); setModels(result); setError(result.length ? undefined : 'No language models are available for this account.') }
    }).catch((failure: unknown) => {
      if (!controller.signal.aborted) setError(failure instanceof Error ? failure.message : 'Could not load models.')
    }).finally(() => { if (!controller.signal.aborted) setLoading(false) })
    return () => controller.abort()
  }, [account.id, attempt])

  async function change(patch: WarmupPatch) {
    const currentRevision = ++saveRevision.current
    setSaving(true)
    setSaveError(undefined)
    try {
      await save(patch)
      if (saveRevision.current === currentRevision && 'startTime' in patch) setStartTimeDirty(false)
    } catch (failure) {
      if (saveRevision.current === currentRevision) {
        setEnabled(status?.enabled ?? false)
        setSelected(status?.model ?? '')
        setStartTime(status?.startTime ?? null)
        setStartTimeDirty(false)
        setSaveError(failure instanceof Error ? failure.message : 'Could not save warm-up settings.')
      }
    } finally {
      if (saveRevision.current === currentRevision) setSaving(false)
    }
  }
  function updateStartTime(next: string | null) {
    setStartTime(next)
    if (status?.enabled) {
      void change({ startTime: next })
    } else if (models.some(model => model.id === selected)) {
      void change({ enabled: true, model: selected, startTime: next })
    } else {
      setStartTimeDirty(true)
    }
  }
  const unavailable = status?.unavailableReason
  const browserTimezone = Intl.DateTimeFormat().resolvedOptions().timeZone
  const showTimezone = Boolean(timezone && browserTimezone && timezone !== browserTimezone)
  const timestamp = status?.needsAttention && status.lastAttemptAt
    ? { label: 'Last attempt', date: status.lastAttemptAt }
    : status?.nextAt && Date.parse(status.nextAt) > Date.now() && !status.needsAttention
    ? { label: 'Next warm-up', date: status.nextAt }
    : account.groups.quotas.nextAttemptAt && Date.parse(account.groups.quotas.nextAttemptAt) > Date.now() && !status?.needsAttention
      ? { label: 'Next check', date: account.groups.quotas.nextAttemptAt }
      : account.groups.quotas.observedAt ? { label: 'Last checked', date: account.groups.quotas.observedAt } : undefined
  const checkboxID = `warmup-${account.id}`
  const timeID = `warmup-start-${account.id}`
  return <div className="warmup-account">
    <label className="warmup-toggle" htmlFor={checkboxID}>
      <span><strong>{account.name}</strong><small>{saving ? 'Saving…' : !status ? 'Loading…' : enabled ? !status.enabled ? 'Choose a model' : status.needsAttention ? 'Needs attention' : unavailable ? 'Waiting' : 'On' : 'Off'}</small></span>
      <span className="switch"><input id={checkboxID} type="checkbox" role="switch" checked={enabled} disabled={disabled || saving || !status || (!enabled && !!unavailable)}
        aria-label={`Warm-up for ${providerName(account.provider)} ${account.name}`}
        aria-describedby={unavailable ? `${checkboxID}-reason` : undefined}
        onChange={event => {
          const next = event.target.checked
          setEnabled(next)
          if (!next || models.some(model => model.id === selected)) {
            void change(startTimeDirty ? { enabled: next, model: selected, startTime } : { enabled: next, model: selected })
          }
        }} /><span aria-hidden="true" /></span>
    </label>
    {unavailable && <p className="warmup-status warmup-unavailable" id={`${checkboxID}-reason`}>{unavailable}{enabled ? '. Your preference is saved.' : ''}</p>}
    <Collapse open={enabled} className="warmup-options">
      <label className="warmup-model"><span>Model</span>
        <select value={selected} disabled={disabled || saving || loading || !models.length || !!unavailable} aria-label={`Warm-up model for ${providerName(account.provider)} ${account.name}`}
          onChange={event => {
            setSelected(event.target.value)
            void change(startTimeDirty ? { enabled: true, model: event.target.value, startTime } : { enabled: true, model: event.target.value })
          }}>
          <option value="" disabled>{loading ? 'Loading models…' : 'Choose a model'}</option>
          {selected && !models.some(model => model.id === selected) && <option value={selected} disabled>{loading ? 'Loading models…' : `${selected} (unavailable)`}</option>}
          {models.map(model => <option key={model.id} value={model.id}>{model.name}</option>)}
        </select>
      </label>
      <div className="warmup-start-time">
        <label htmlFor={startTime !== null ? timeID : undefined}>First warm-up</label>
        <div className="warmup-time-control">
          {startTime !== null ? <>
            <input id={timeID} type="time" value={startTime} disabled={disabled || !!unavailable}
              aria-label={`First warm-up time for ${providerName(account.provider)} ${account.name}`}
              onChange={event => {
                if (!TIME_RE.test(event.target.value)) return
                updateStartTime(event.target.value)
              }} />
            <button type="button" className="quiet-button" disabled={disabled || saving || !!unavailable}
              onClick={() => updateStartTime(null)}>Any time</button>
            {showTimezone && <span className="warmup-timezone">{timezone}</span>}
          </> : <>
            <span className="warmup-time-any">Any time</span>
            <button type="button" className="quiet-button" disabled={disabled || saving || !!unavailable}
              onClick={() => updateStartTime('04:00')}>Set time</button>
          </>}
        </div>
      </div>
      {!status?.enabled && !error && <p className="warmup-status">Choose a model to start warming.</p>}
      {status?.needsAttention && <p className="note-warn" role="status">{status.message} <button className="quiet-button" disabled={disabled || saving || loading || !models.some(model => model.id === selected)} onClick={() => void change(startTimeDirty ? { enabled: true, model: selected, startTime } : { enabled: true, model: selected })}>Resume</button></p>}
      {status?.enabled && timestamp && <dl className="warmup-schedule"><dt>{timestamp.label}</dt><dd><time dateTime={timestamp.date}><span>{new Date(timestamp.date).toLocaleDateString(undefined, { timeZone: timezone, dateStyle: 'medium' })}</span><span>{new Date(timestamp.date).toLocaleTimeString(undefined, { timeZone: timezone, timeStyle: 'short' })}</span></time></dd></dl>}
    </Collapse>
    {error && (enabled || saving) && <p className="note-warn" role="alert">{error} <button className="quiet-button" disabled={loading || saving} onClick={() => setAttempt(attempt + 1)}>Retry</button></p>}
    {saveError && <p className="note-warn" role="alert">{saveError}</p>}
  </div>
}
