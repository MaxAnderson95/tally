import { useEffect, useReducer, useState } from 'react'
import type { Account, Credit } from './api'
import { creditUsable, RedemptionClient, redemptionLabel } from './redemptions'

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
  return {
    warning: unknown ? <button className="details-toggle" aria-label={`Unknown reset outcome for ${account.name}`} aria-expanded={explanation} onClick={() => setExplanation(!explanation)}><svg width="16" height="16" viewBox="0 0 20 20" aria-hidden="true"><path d="M10 2 19 18H1Z M10 7v5 M10 14v1" fill="none" stroke="currentColor" strokeWidth="1.5" /></svg></button> : null,
    result: <>
      {client.operation && client.operation.state !== 'pending' && (!unknown || explanation) && <div className="reset-result" role={unknown ? 'alert' : 'status'}>
        <p>{redemptionLabel(client.operation, account)}</p>
        {client.operation.acknowledgementRequired && <button disabled={client.busy} onClick={async () => { const work = client.acknowledge(); render(); await work; render(); window.dispatchEvent(new Event('tally:operation')) }}>{client.busy ? 'Acknowledging…' : 'Acknowledge'}</button>}
      </div>}
      {unknown && explanation && !client.operation && <p role="alert">Outcome unknown. Reading the existing operation before acknowledgement.</p>}
      {client.error && <p role="alert">{client.error}</p>}
    </>,
    action: (credit: Credit) => <>
      <button disabled={blocked || client.storageUnavailable || !creditUsable(credit)} onClick={() => setConfirming(credit.id)}>{blocked && (client.operation ? client.operation.selectedCreditId ?? client.operation.requestedCreditId : chosen) === credit.id && !unknown ? 'Redeeming…' : 'Use'}</button>
      {confirming === credit.id && !blocked && <div className="reset-confirm">
        <p>Use this credit on <strong>{account.name}</strong>? This consumes one credit and cannot be undone.</p>
        <div><button onClick={() => setConfirming(undefined)}>Cancel</button><button onClick={() => void submit(credit)}>Use credit</button></div>
      </div>}
    </>,
  }
}
