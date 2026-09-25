import { useState, type CSSProperties } from 'react'
import { balanceLabel, clockLabel, groupIsStale, moneyLabel, overviewWindows, percentage, quotaWarning, resetCountLabel, type Account, type Fault } from './api'
import { providerName } from './ProviderLogo'
import { useResetControls } from './ResetControls'
import { QuotaRow, TallyMeter, Warning } from './QuotaRow'
import { ColorPicker, type PreferenceChange } from './AccountPreferences'
import { Collapse } from './motion'

type RowProps = {
  account: Account; timezone: string; disconnected: boolean; inventoryError: Fault | null; now: number
  save: (change: PreferenceChange) => Promise<boolean>; saving: boolean; warmupWarning?: string
  activate: (id: string) => Promise<void>; switching?: string
}

function extraSummary(account: Account) {
  const extra = account.groups.extraUsage.data
  switch (extra?.presentation) {
    case 'off': return 'Off'
    case 'bounded': return `${moneyLabel(extra.remaining)} left`
    case 'used_only': return `${moneyLabel(extra.used)} used`
    default: return 'Unavailable'
  }
}

export function AccountRow({ account, timezone, disconnected, inventoryError, now, save, saving, warmupWarning, activate, switching }: RowProps) {
  const quota = account.groups.quotas
  const windows = overviewWindows(account)
  const quotaStale = disconnected || groupIsStale(quota, now)
  const extraLabel = account.provider === 'xai' ? 'PAYG' : 'Extra usage'
  const [details, setDetails] = useState(false)
  const resets = useResetControls(account)
  const stale = quotaStale || windows.some(window => window.stale || (window.resetAt !== null && Date.parse(window.resetAt) <= now))
  const warning = quotaWarning(account, disconnected, inventoryError, now)
  const errors = [...new Set(Object.values(account.groups).flatMap(group => group.error ? [group.error.message] : []))]
  const plan = account.groups.plan.data?.name
  const provider = providerName(account.provider)
  const selectable = account.active != null && !disconnected && !inventoryError
  const detailsId = `details-${account.id}`
  return <article className="account" data-open={details} aria-label={`${provider} ${account.name}`}>
    <div className="account-identity">
      <ColorPicker account={account} save={save} disabled={saving || disconnected} />
      <div className="account-name">
        <h3>{account.name}</h3>
        <p>{provider}{plan && !provider.toLowerCase().endsWith(plan.toLowerCase()) && <> {plan}</>}{!plan && ' plan unknown'}</p>
      </div>
      <div className="account-flags">
        {stale && <span className="flag-warning" tabIndex={0} aria-label={warning || 'Stale reading'}><Warning /><span role="tooltip">{warning || 'Last-good values may be out of date.'}</span></span>}
        {resets.warning}
      </div>
    </div>
    <div className="account-selection">
      {account.active === true && selectable ? <span className="active-mark">Active in OpenCode</span>
        : <button className="quiet-button" disabled={!!switching || !selectable} onClick={() => void activate(account.id)}>{switching === account.id ? 'Switching…' : 'Use in OpenCode'}</button>}
      {!selectable && <span className="muted">Selection unavailable</span>}
    </div>
    <div className="account-windows" style={{ '--count': Math.max(1, windows.length) } as CSSProperties}>
      {windows.length === 0 ? <div className="window-missing"><TallyMeter percent={null} label="Quota" uncertain /><p>{quota.observedAt ? 'No quota windows reported' : 'Quota unavailable'}</p></div>
        : windows.map(window => <QuotaRow key={window.id} window={window} stale={quotaStale} now={now} />)}
    </div>
    <div className="account-facts">
      {(account.provider === 'anthropic' || account.provider === 'xai') && <span><span className="muted">{extraLabel}</span> {extraSummary(account)}{(disconnected || groupIsStale(account.groups.extraUsage)) && ' (out of date)'}</span>}
      {account.provider === 'openai' && <>
        <span><span className="muted">Credits</span> {account.groups.balances.data?.items.map(balanceLabel).join(', ') ?? 'Unavailable'}{(disconnected || groupIsStale(account.groups.balances)) && ' (out of date)'}</span>
        <span><span className="muted">Resets</span> {account.groups.resetSummary.data?.availableCount ?? '?'}</span>
      </>}
      <button className="account-toggle" aria-expanded={details} aria-controls={detailsId} onClick={() => setDetails(!details)}>
        {details ? 'Less' : 'More'}<svg viewBox="0 0 12 12" aria-hidden="true"><path d="M3 4.5 6 7.5 9 4.5" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" /></svg>
      </button>
    </div>
    {(warmupWarning || resets.hasResult) && <div className="account-notes">
      {resets.result}
      {warmupWarning && <p className="note-warn" role="status">Auto warm-up: {warmupWarning} Review it in Settings.</p>}
    </div>}
    <Collapse open={details} id={detailsId} className="account-details">
      {errors.map(error => <p className="note-warn" role="alert" key={error}>{error}</p>)}
      {windows.some(window => window.resetAt) && <dl className="facts">{windows.filter(window => window.resetAt).map(window => {
        const pacing = !quotaStale && !window.stale && window.resetAt && Date.parse(window.resetAt) > now ? window.pacing : null
        return <div key={window.id}>
          <dt>{window.label}</dt>
          <dd>Resets {clockLabel(Date.parse(window.resetAt!), timezone, now)}{pacing && <span className="muted">{pacing.runOutAt ? `At this pace, runs out ${clockLabel(Date.parse(pacing.runOutAt), timezone, now)}` : 'At this pace, lasts until reset'}</span>}</dd>
        </div>
      })}</dl>}
      {(account.provider === 'anthropic' || account.provider === 'xai') && <section className="detail-block" aria-label={extraLabel}>
        <h4>{extraLabel}</h4>
        {account.groups.extraUsage.data?.presentation === 'bounded' ? <div className="window">
          <span className="window-label">Left</span>
          <TallyMeter percent={account.groups.extraUsage.data.remainingPercent} label={extraLabel} />
          <strong className="window-percent">{percentage(account.groups.extraUsage.data.remainingPercent)}</strong>
          <p className="window-timing"><span>{moneyLabel(account.groups.extraUsage.data.used)} used of {moneyLabel(account.groups.extraUsage.data.limit)}</span></p>
        </div> : <p>{extraSummary(account)}</p>}
      </section>}
      {account.provider === 'openai' && <section className="detail-block" aria-label="Reset credits">
        <h4>{resetCountLabel(account.groups.resetSummary.data)}</h4>
        {(disconnected || groupIsStale(account.groups.resetSummary)) && <p className="muted">This count is out of date.</p>}
        {account.groups.resetDetails.data === null ? <p className="muted">Credit list unavailable</p>
          : account.groups.resetDetails.data.credits.length === 0 ? <p className="muted">No reset credits reported</p>
          : <ul className="credits">{account.groups.resetDetails.data.credits.map(credit => <li key={credit.id}>
            <div><strong>{credit.title ?? 'Reset credit'}</strong>
              <span className="muted">{credit.expiry.kind === 'at' ? `Expires ${new Date(credit.expiry.at).toLocaleDateString(undefined, { timeZone: timezone, dateStyle: 'medium' })}` : credit.expiry.kind === 'none' ? 'No expiry' : 'Expiry unknown'}{credit.available === false && ', unavailable'}</span>
              {credit.description && <span className="muted">{credit.description}</span>}
            </div>
            {resets.action(credit)}
          </li>)}</ul>}
        <p className="fine-print">Using a credit asks for confirmation first. OpenAI decides which windows reset.</p>
      </section>}
      {windows.some(window => window.pacing) && <p className="fine-print">Pace estimates assume your average usage rate continues.</p>}
    </Collapse>
  </article>
}
