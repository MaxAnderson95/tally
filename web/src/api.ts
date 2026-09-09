export type Fault = { code: string; message: string; retryAt: string | null; blockingOperationId: string | null }
export type Group<T> = {
  data: T | null; observedAt: string | null; lastAttemptAt: string | null
  stale: boolean; refreshing: boolean; nextAttemptAt: string | null; error: Fault | null
}
export type QuotaWindow = {
  id: string; label: string; scope: string; scopeNote: string | null; modelId: string | null
  cadence: string; durationSeconds: number | null; durationSource: string
  usedPercent: number | null; remainingPercent: number | null; resetAt: string | null
  resetState: 'scheduled' | 'passed' | 'not_started' | 'unknown'; stale: boolean
  displayInOverview: boolean
  pacing: { projectedUsedPercent: number; sparePercent: number; runOutAt: string | null; runOutReason: string | null } | null
  pacingUnavailableReason: string | null
}
export type Account = {
  id: string; provider: string; service: string; name: string; pinned: boolean; pinOrder: number | null
  identityColorIndex: number
  pin: { lines: { windowId: string; label: string; remainingPercent: number | null; stale: boolean }[]; warning: boolean }
  groups: {
    plan: Group<{ name: string }>; quotas: Group<{ windows: QuotaWindow[] }>
    extraUsage: Group<ExtraUsage>; balances: Group<{ items: Balance[] }>; resetSummary: Group<ResetSummary>; resetDetails: Group<{ credits: Credit[]; summary: ResetSummary }>
  }
  command: { blockingOperationId: string | null; state: 'pending' | 'unknown' | null; acknowledgementRequired: boolean }
}
export type Money = {
  amount: string; currency: string; provenance: 'provider' | 'reference_conversion'
  source: { amount: string; unit: string; exponent: number | null }
}
export type Balance = { unit: string; quantity: string | null; money: Money | null; referenceValue: Money | null; unlimited: boolean | null }
export type ResetSummary = { availableCount: number | null; applicableAvailableCount: number | null; source: 'usage' | 'credit_details' }
export type Credit = {
  id: string; type: string | null; status: string | null; available: boolean | null
  title: string | null; description: string | null; grantedAt: string | null
  expiry: { kind: 'at'; at: string } | { kind: 'none' | 'unknown'; at: null }
}
export const balanceLabel = (balance: Balance) => balance.unlimited === true ? `Unlimited ${balance.unit}` : `${balance.quantity ?? 'Unknown'} ${balance.unit}${balance.referenceValue ? ` (${moneyLabel(balance.referenceValue)})` : ''}`
export const resetCountLabel = (summary: ResetSummary | null) => summary?.availableCount == null ? 'Reset count unavailable' : `${summary.availableCount} reset credits`
export const creditExpiryLabel = (credit: Credit, timezone: string) => credit.expiry.kind === 'at' ? new Date(credit.expiry.at).toLocaleString(undefined, { timeZone: timezone }) : credit.expiry.kind === 'none' ? 'Does not expire' : 'Expiry unknown'
export type ExtraUsage = {
  enabled: boolean | null; used: Money | null; limit: Money | null; remaining: Money | null
  remainingPercent: number | null; periodLabel: string | null
  presentation: 'off' | 'used_only' | 'bounded' | 'unavailable'
}
export const moneyLabel = (money: Money | null) => money ? `${money.currency} ${money.amount}` : 'Unavailable'
export const overviewWindows = (account: Account) => (account.groups.quotas.data?.windows.filter(window => window.displayInOverview) ?? []).sort((a, b) => (a.durationSeconds ?? Infinity) - (b.durationSeconds ?? Infinity) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
export type Status = {
  apiMajor: 1; appBuild: string; serverTime: string; timezone: string; owner: 'ready' | 'shutting_down'
  inventory: Group<{ count: number; namespaceId: string }>
  recoveryStorage: { available: boolean; error: Fault | null }
}
export type AccountsResponse = { status: Status; accounts: Account[] }
export type Schedule = { state: 'started' | 'joined' | 'deferred' | 'blocked'; nextAttemptAt: string | null; reason: Fault | null }
export type RefreshResponse = { accounts: { accountId: string; schedule: Schedule }[]; activity: Schedule }
export type Redemption = {
  operationId: string; accountId: string; accountName: string
  requestedCreditId: string | null; selectedCreditId: string | null
  createdAt: string; updatedAt: string
  state: 'pending' | 'confirmed' | 'nothing_to_reset' | 'no_credit' | 'failed' | 'unknown'
  providerResult: { code: string; windowsReset: number | null } | null
  error: Fault | null; acknowledgementRequired: boolean; acknowledgedAt: string | null; resultUrl: string
}

export function scheduleLabel(schedule: Schedule): string {
  const label = { started: 'Refresh requested', joined: 'Joined existing refresh', deferred: 'Deferred', blocked: 'Blocked' }[schedule.state]
  return schedule.reason ? `${label}: ${schedule.reason.message}` : label
}

export function groupIsStale(group: Group<unknown>, now = Date.now()): boolean {
  return group.stale || group.observedAt === null || now - Date.parse(group.observedAt) >= 300_000
}

export function decodeAccounts(text: string): AccountsResponse {
  const result: AccountsResponse = JSON.parse(text)
  if (result.status.apiMajor !== 1) throw new Error('Update Tally: this API version is incompatible.')
  return result
}

export const percentage = (value: number | null) => value === null ? '?' : `${Math.round(value)}%`

export function resetLabel(window: QuotaWindow, now = Date.now()): string {
  if (!window.resetAt) return ''
  if (window.resetAt && Date.parse(window.resetAt) <= now) return 'Reset time passed; awaiting update'
  return `Resets in ${countdown(Date.parse(window.resetAt), now)}`
}

export function countdown(deadline: number, now = Date.now()): string {
  const minutes = Math.max(0, Math.ceil((deadline - now) / 60_000))
  if (minutes >= 1440) return `${Math.floor(minutes / 1440)}d ${Math.floor(minutes / 60) % 24}h`
  return `${Math.floor(minutes / 60)}h ${minutes % 60}m`
}

export function earlyLimitDate(window: QuotaWindow, stale: boolean, now = Date.now()): number | null {
  if (stale || window.stale || window.usedPercent === null || window.usedPercent < 5 || !window.resetAt || Date.parse(window.resetAt) <= now) return null
  return window.pacing?.runOutAt ? Date.parse(window.pacing.runOutAt) : null
}

export function quotaWarning(account: Account, disconnected: boolean, inventoryError: Fault | null, now = Date.now()): string {
  const quota = account.groups.quotas
  const reasons: string[] = []
  if (disconnected) reasons.push('Cannot reach Tally. Displayed readings may be out of date.')
  const error = quota.error ?? inventoryError
  if (error) reasons.push(error.message)
  if (groupIsStale(quota, now)) reasons.push(quota.observedAt ? `Showing an older reading from ${new Date(quota.observedAt).toLocaleString()}.` : 'No successful quota reading yet.')
  for (const window of quota.data?.windows ?? []) {
    if (window.resetAt && Date.parse(window.resetAt) <= now) reasons.push(`${window.label}: reset time passed; awaiting an updated reading.`)
  }
  return reasons.join('\n')
}
