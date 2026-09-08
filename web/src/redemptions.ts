import type { Account, Credit, Fault, Redemption, Status } from './api.ts'

export function creditUsable(credit: Credit, now = Date.now()) {
  return credit.available === true && (credit.expiry.kind !== 'at' || Date.parse(credit.expiry.at) > now)
}

export function redemptionLabel(operation: Redemption, account: Account) {
  switch (operation.state) {
    case 'pending': return 'Redeeming…'
    case 'confirmed': return account.groups.quotas.stale || account.groups.quotas.error || account.groups.resetDetails.error
      ? 'Reset confirmed. Current usage readings are stale or unavailable.'
      : operation.providerResult?.code === 'already_redeemed' ? 'Credit already redeemed; no additional reset claimed.' : 'Reset confirmed.'
    case 'nothing_to_reset': return 'Provider reports nothing to reset.'
    case 'no_credit': return 'No available reset credit.'
    case 'failed': return operation.error?.message ?? 'Reset failed before consumption.'
    case 'unknown': return operation.acknowledgementRequired
      ? 'Outcome unknown. A credit may have been consumed. Acknowledge to allow another deliberate reset; the outcome stays unknown and acknowledgement never retries consumption.'
      : 'Outcome unknown; acknowledged. No consumption was retried.'
  }
}

// The browser keeps only identity. The owner's journal remains authoritative.
export class RedemptionClient {
  operation: Redemption | undefined
  operationId: string | null
  error: string | undefined
  busy = false
  storageUnavailable = false
  private reading = false
  private revision = 0
  private readonly key: string
  readonly accountId: string
  private storage: Pick<Storage, 'getItem' | 'setItem' | 'removeItem'>
  private transport: typeof fetch

  constructor(accountId: string, storage: Pick<Storage, 'getItem' | 'setItem' | 'removeItem'>, transport: typeof fetch = (input, init) => fetch(input, init)) {
    this.accountId = accountId; this.storage = storage; this.transport = transport
    this.key = `tally.redemption.${accountId}`
    try { this.operationId = storage.getItem(this.key) }
    catch { this.operationId = null; this.storageUnavailable = true; this.error = 'Operation identity storage unavailable; reset controls disabled.' }
  }

  get blocked() { return this.busy || (!!this.operationId && (!this.operation || this.operation.state === 'pending' || this.operation.acknowledgementRequired)) }

  async recover(id = this.operationId) {
    if (!id || this.reading || this.busy) return
    if (id !== this.operationId && this.blocked) id = this.operationId
    if (!id) return
    this.reading = true
    const revision = this.revision
    this.operationId = id
    try {
      this.storage.setItem(this.key, id)
      const response = await this.transport(`/api/v1/redemptions/${encodeURIComponent(id)}`, { cache: 'no-store', signal: AbortSignal.timeout(10_000) })
      if (!response.ok) {
        const body: { error: Fault } = await response.json()
        if ((response.status === 404 && body.error.code === 'operation_not_found') || (response.status === 400 && body.error.code === 'invalid_request')) {
          const statusResponse = await this.transport('/api/v1/status', { cache: 'no-store', signal: AbortSignal.timeout(10_000) })
          if (!statusResponse.ok) throw new Error('Owner status unavailable')
          const status: Status = await statusResponse.json()
          if (revision !== this.revision) return
          if (status.apiMajor === 1 && status.recoveryStorage.available) {
            this.storage.removeItem(this.key)
            this.operationId = null
            this.operation = undefined
            this.error = 'Saved operation is not available on this owner. No reset was resent.'
            return
          }
        }
        throw new Error('Operation unavailable')
      }
      const operation: Redemption = await response.json()
      if (revision !== this.revision) return
      this.operation = operation
      this.error = undefined
    } catch { if (revision === this.revision) this.error = 'Operation update unavailable. Keeping the existing request; no reset will be resent.' }
    finally { this.reading = false }
  }

  async submit(creditId: string) {
    if (this.blocked || this.storageUnavailable) return
    const id = crypto.randomUUID()
    try { this.storage.setItem(this.key, id) }
    catch { this.storageUnavailable = true; this.error = 'Cannot save operation identity. No reset was sent.'; return }
    this.revision++
    this.operationId = id
    this.operation = undefined
    this.busy = true
    try {
      const response = await this.transport(`/api/v1/accounts/${encodeURIComponent(this.accountId)}/redemptions`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ operationId: id, creditId }), signal: AbortSignal.timeout(20_000),
      })
      if (!response.ok) {
        const body: { error: { code: string; message: string; blockingOperationId: string | null } } = await response.json()
        // A rejected request can still name a durable block created by another client.
        if (body.error.blockingOperationId) {
          this.operationId = body.error.blockingOperationId
          this.storage.setItem(this.key, this.operationId)
        } else if (body.error.code !== 'recovery_storage_unavailable') {
          this.storage.removeItem(this.key)
          this.operationId = null
          this.error = body.error.message
          return
        }
        throw new Error(body.error.message)
      }
      this.operation = await response.json()
      this.error = undefined
    } catch { this.error = 'Submission response unavailable. Reading the existing request; no reset will be resent.' }
    finally { this.busy = false }
    await this.recover()
  }

  async acknowledge() {
    if (!this.operation?.acknowledgementRequired || this.busy) return
    this.revision++
    this.busy = true
    try {
      this.operation = await this.request(`/redemptions/${encodeURIComponent(this.operation.operationId)}/acknowledge`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' })
      this.error = undefined
    } catch { this.error = 'Acknowledgement not confirmed. The warning and existing request are retained.' }
    finally { this.busy = false }
  }

  private async request(path: string, init?: RequestInit): Promise<Redemption> {
    const response = await this.transport(`/api/v1${path}`, { cache: 'no-store', ...init, signal: AbortSignal.timeout(10_000) })
    if (!response.ok) throw new Error('Operation unavailable')
    return response.json()
  }
}
