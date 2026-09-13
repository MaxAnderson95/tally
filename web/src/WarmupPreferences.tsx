import { useEffect, useRef, useState } from 'react'
import type { Account, Fault, WarmupModel, WarmupReading } from './api'
import { ProviderLogo, providerName } from './ProviderLogo'

type Readings = Record<string, WarmupReading>

async function request<T>(url: string, options: RequestInit = {}): Promise<T> {
  const response = await fetch(url, { cache: 'no-store', ...options })
  if (!response.ok) {
    const body: { error: Fault } = await response.json()
    throw new Error(body.error.message)
  }
  return response.json()
}

export function useWarmups() {
  const [readings, setReadings] = useState<Readings>()
  const [error, setError] = useState<string>()
  const [saving, setSaving] = useState(false)
  const writing = useRef(false)
  const revision = useRef(0)
  useEffect(() => {
    const controller = new AbortController()
    let inFlight = false
    async function poll() {
      if (document.hidden || inFlight || writing.current) return
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
  async function save(accountID: string, enabled: boolean, model: string) {
    if (writing.current) throw new Error('Another warm-up preference is being saved. Try again.')
    writing.current = true
    setSaving(true)
    revision.current++
    try {
      const next = await request<Readings>(`/api/v1/accounts/${encodeURIComponent(accountID)}/warmup`, {
        method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ enabled, model }), signal: AbortSignal.timeout(10_000),
      })
      setReadings(next)
      setError(undefined)
    } finally {
      revision.current++
      writing.current = false
      setSaving(false)
      window.dispatchEvent(new Event('tally:operation'))
    }
  }
  return { readings, error, saving, save }
}

export function WarmupPreferences({ accounts, timezone, disabled, warmups }: { accounts: Account[]; timezone: string; disabled: boolean; warmups: ReturnType<typeof useWarmups> }) {
  const { readings, error } = warmups
  return <div className="warmup-preferences">
    <p className="warmup-intro">Start five-hour windows before you sit down to code. Choose a model for each account you enable.</p>
    {error && <p className="account-error" role="alert">{error}</p>}
    {!readings && !error && <p role="status">Loading warm-up settings…</p>}
    {['anthropic', 'openai', 'opencode-go', 'xai'].map(provider => {
      const matches = accounts.filter(account => account.provider === provider)
      return matches.length > 0 && <section className="warmup-provider" key={provider} aria-label={providerName(provider)}>
        <h3><ProviderLogo provider={provider} color={0} />{providerName(provider)}</h3>
        {matches.map(account => <WarmupAccount key={account.id} account={account} status={readings?.[account.id]} timezone={timezone} disabled={disabled || !!error || warmups.saving}
          save={(enabled, model) => warmups.save(account.id, enabled, model)} />)}
      </section>
    })}
  </div>
}

function WarmupAccount({ account, status, timezone, disabled, save }: {
  account: Account; status: WarmupReading | undefined; timezone: string; disabled: boolean
  save: (enabled: boolean, model: string) => Promise<void>
}) {
  const [models, setModels] = useState<WarmupModel[]>([])
  const [selected, setSelected] = useState(status?.model ?? '')
  const [enabled, setEnabled] = useState(status?.enabled ?? false)
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [saveError, setSaveError] = useState<string>()
  const [error, setError] = useState<string>()
  const [attempt, setAttempt] = useState(0)
  useEffect(() => { if (status) { setSelected(status.model); setEnabled(status.enabled) } }, [status?.model, status?.enabled])
  useEffect(() => {
    const controller = new AbortController()
    setLoading(true)
    void request<WarmupModel[]>(`/api/v1/accounts/${encodeURIComponent(account.id)}/warmup/models`, {
      signal: AbortSignal.any([controller.signal, AbortSignal.timeout(20_000)]),
    }).then(result => {
      if (!controller.signal.aborted) { setModels(result); setError(result.length ? undefined : 'No language models are available for this account.') }
    }).catch((failure: unknown) => {
      if (!controller.signal.aborted) setError(failure instanceof Error ? failure.message : 'Could not load models.')
    }).finally(() => { if (!controller.signal.aborted) setLoading(false) })
    return () => controller.abort()
  }, [account.id, attempt])

  async function change(nextEnabled: boolean, model: string) {
    setSaving(true)
    setSaveError(undefined)
    try { await save(nextEnabled, model) }
    catch (failure) { setEnabled(status?.enabled ?? false); setSelected(status?.model ?? ''); setSaveError(failure instanceof Error ? failure.message : 'Could not save warm-up settings.') }
    finally { setSaving(false) }
  }
  const unavailable = status?.unavailableReason
  const timestamp = status?.needsAttention && status.lastAttemptAt
    ? { label: 'Last attempt', date: status.lastAttemptAt }
    : status?.nextAt && Date.parse(status.nextAt) > Date.now() && !status.needsAttention
    ? { label: 'Next warm-up', date: status.nextAt }
    : account.groups.quotas.nextAttemptAt && Date.parse(account.groups.quotas.nextAttemptAt) > Date.now() && !status?.needsAttention
      ? { label: 'Next check', date: account.groups.quotas.nextAttemptAt }
      : account.groups.quotas.observedAt ? { label: 'Last checked', date: account.groups.quotas.observedAt } : undefined
  const checkboxID = `warmup-${account.id}`
  return <div className="warmup-account">
    <label className="warmup-toggle" htmlFor={checkboxID}>
      <span>{account.name}</span>
      <input id={checkboxID} type="checkbox" checked={enabled && !unavailable} disabled={disabled || saving || !status || !!unavailable}
        aria-describedby={unavailable ? `${checkboxID}-reason` : undefined}
        onChange={event => {
          const next = event.target.checked
          setEnabled(next)
          if (!next || models.some(model => model.id === selected)) void change(next, selected)
        }} />
    </label>
    {unavailable && <p className="warmup-status" id={`${checkboxID}-reason`}>{unavailable}</p>}
    {enabled && !unavailable && <>
      <label className="warmup-model"><span>Model</span>
        <select value={selected} disabled={disabled || saving || loading || !models.length} aria-label={`Warm-up model for ${providerName(account.provider)} ${account.name}`}
          onChange={event => { setSelected(event.target.value); void change(true, event.target.value) }}>
          <option value="" disabled>{loading ? 'Loading models…' : 'Choose a model'}</option>
          {selected && !models.some(model => model.id === selected) && <option value={selected} disabled>{selected}{loading ? '' : ' (unavailable)'}</option>}
          {models.map(model => <option key={model.id} value={model.id}>{model.name}</option>)}
        </select>
      </label>
      {loading && <p className="warmup-status" role="status">Loading models…</p>}
      {!status?.enabled && !error && <p className="warmup-status">Choose a model to start warming.</p>}
      {status?.needsAttention && <p className="account-error" role="status">{status.message} <button disabled={disabled || saving || loading || !models.some(model => model.id === selected)} onClick={() => void change(true, selected)}>Resume</button></p>}
    </>}
    {status?.enabled && timestamp && <p className="warmup-status">{timestamp.label}: <time dateTime={timestamp.date}>{new Date(timestamp.date).toLocaleString(undefined, { timeZone: timezone, dateStyle: 'medium', timeStyle: 'short' })}</time></p>}
    {error && (enabled || saving) && <p className="account-error" role="alert">{error} <button disabled={loading || saving} onClick={() => setAttempt(attempt + 1)}>Retry</button></p>}
    {saveError && <p className="account-error" role="alert">{saveError}</p>}
  </div>
}
