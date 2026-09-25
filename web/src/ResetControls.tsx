import { useEffect, useReducer, useState } from 'react'
import type { Account, Credit } from './api'
import { creditUsable, RedemptionClient, redemptionLabel } from './redemptions'
import { Warning } from './QuotaRow'
import { Collapse } from './motion'

export function useResetControls(account: Account) {
  const [client] = useState(() => new RedemptionClient(account.id, {
    getItem: key => localStorage.getItem(key), setItem: (key, value) => localStorage.setItem(key, value), removeItem: key => localStorage.removeItem(key),
  }))
  const [, render] = useReducer(value => value + 1, 0)
  const [confirming, setConfirming] = useState<string>()
  const [chosen, setChosen] = useState<string>()
  const [explanation, setExplanation] = useState(false)
  const blockingId = account.command.blockingOperationId
  useEffect(() => {
    let stopped = false
    async function poll() {
      if (document.hidden) return
      const previous = client.operation?.updatedAt
      await client.recover(blockingId ?? client.operationId)
      if (previous !== client.operation?.updatedAt) window.dispatchEvent(new Event('tally:operation'))
      if (!stopped) render()
    }
    void poll()
    const interval = setInterval(() => { if (blockingId || client.blocked) void poll() }, 1000)
    document.addEventListener('visibilitychange', poll)
    return () => { stopped = true; clearInterval(interval); document.removeEventListener('visibilitychange', poll) }
  }, [client, blockingId])
  const blocked = client.blocked || !!blockingId
  const unknown = client.operation?.acknowledgementRequired || account.command.acknowledgementRequired
  async function submit(credit: Credit) {
    if (blocked || !creditUsable(credit)) return
    setConfirming(undefined); setChosen(credit.id)
    const work = client.submit(credit.id); render()
    await work; render(); window.dispatchEvent(new Event('tally:operation'))
  }
  const settled = !!client.operation && client.operation.state !== 'pending' && (!unknown || explanation)
  const dismissible = settled && !client.operation?.acknowledgementRequired ? `${client.operation?.operationId}:${client.operation?.state}` : null
  // Matches the Mac app: the window starts when the outcome is first visible, so a result settled while the page was hidden is not lost unseen.
  useEffect(() => {
    if (!dismissible) return
    let timer: ReturnType<typeof setTimeout> | undefined
    const start = () => { if (!document.hidden && timer === undefined) timer = setTimeout(() => { client.dismiss(); render() }, 10_000) }
    start()
    document.addEventListener('visibilitychange', start)
    return () => { clearTimeout(timer); document.removeEventListener('visibilitychange', start) }
  }, [client, dismissible])
  const reading = !!unknown && explanation && !client.operation
  return {
    warning: unknown ? <button className="flag-warning flag-button" aria-label={`Unknown reset outcome for ${account.name}`} title="The reset outcome is unknown. Review and acknowledge it before using another credit." aria-expanded={explanation} onClick={() => setExplanation(!explanation)}><Warning /></button> : null,
    hasResult: settled || reading || !!client.error,
    result: <>
      {settled && client.operation && <div className="reset-result" role={unknown ? 'alert' : 'status'}>
        <p>{redemptionLabel(client.operation, account)}</p>
        {client.operation.acknowledgementRequired && <button disabled={client.busy} onClick={async () => { const work = client.acknowledge(); render(); await work; render(); window.dispatchEvent(new Event('tally:operation')) }}>{client.busy ? 'Acknowledging…' : 'Acknowledge'}</button>}
      </div>}
      {reading && <p role="alert">Outcome unknown. Reading the existing operation before acknowledgement.</p>}
      {client.error && <p className="note-warn" role="alert">{client.error}</p>}
    </>,
    action: (credit: Credit) => <>
      {(confirming !== credit.id || blocked) && <button className="quiet-button" disabled={blocked || client.storageUnavailable || !creditUsable(credit)} onClick={() => setConfirming(credit.id)}>{blocked && (client.operation ? client.operation.selectedCreditId ?? client.operation.requestedCreditId : chosen) === credit.id && !unknown ? 'Redeeming…' : 'Use credit'}</button>}
      <Collapse open={confirming === credit.id && !blocked} className="reset-confirm">
        <p>Use this credit on <strong>{account.name}</strong>? This consumes one credit and cannot be undone.</p>
        <div><button className="quiet-button" onClick={() => setConfirming(undefined)}>Cancel</button><button className="primary-button" onClick={() => void submit(credit)}>Use credit</button></div>
      </Collapse>
    </>,
  }
}
