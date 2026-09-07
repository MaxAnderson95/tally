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
    extraUsage: Group<unknown>; balances: Group<unknown>; resetSummary: Group<unknown>; resetDetails: Group<unknown>
  }
  command: { blockingOperationId: string | null; state: 'pending' | 'unknown' | null; acknowledgementRequired: boolean }
}
export type Status = {
  apiMajor: 1; appBuild: string; serverTime: string; timezone: string; owner: 'ready' | 'shutting_down'
  inventory: Group<{ count: number; namespaceId: string }>
  recoveryStorage: { available: boolean; error: Fault | null }
}
export type AccountsResponse = { status: Status; accounts: Account[] }

export function decodeAccounts(text: string): AccountsResponse {
  const result: AccountsResponse = JSON.parse(text)
  if (result.status.apiMajor !== 1) throw new Error('Update Tally: this API version is incompatible.')
  return result
}

export const percentage = (value: number | null) => value === null ? '?' : `${Math.round(value)}%`

export function resetLabel(window: QuotaWindow, now = Date.now()): string {
  if (window.resetAt && Date.parse(window.resetAt) <= now) return 'Reset time passed; awaiting update'
  if (!window.resetAt) return window.resetState === 'not_started' ? 'Not started' : 'Reset time unavailable'
  const minutes = Math.max(1, Math.ceil((Date.parse(window.resetAt) - now) / 60_000))
  if (minutes < 60) return `Resets in ${minutes}m`
  if (minutes < 1440) return `Resets in ${Math.floor(minutes / 60)}h ${minutes % 60}m`
  return `Resets in ${Math.floor(minutes / 1440)}d ${Math.floor(minutes % 1440 / 60)}h`
}
