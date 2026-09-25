import type { Group, Status } from './api'

export type ActivityRange = 'today' | 'yesterday' | 'last30days'
export type Provider = 'anthropic' | 'openai' | 'opencode-go' | 'xai'
export type Tokens = { input: number; output: number; reasoning: number; cacheRead: number; cacheWrite: number; total: number }
export type PricingCoverage = {
  fullyPricedRows: number; boundedRows: number; partiallyPricedRows: number; unpricedRows: number; missingUsageRows: number
  pricedComponents: Tokens; unpricedComponents: Tokens
}
export type Estimate = {
  status: 'scalar' | 'range' | 'partial' | 'unpriced' | 'empty'; currency: 'USD'; lower: string | null; upper: string | null
  coverage: PricingCoverage
  exclusions: { provider: Provider; modelId: string; reason: string; rows: number; tokens: Tokens | null }[]
}
export type Aggregate = {
  rows: number; missingUsageRows: number; tokens: Tokens | null
  recordedCost: { amount: string | null; currency: 'USD'; rowsWithCost: number; missingCostRows: number; ambiguousZeroRows: number }
  estimate: Estimate
}
export type ActivityData = {
  range: ActivityRange; startAt: string; endAt: string; timezone: string
  source: {
    namespaceId: string; schemaRevision: string; attribution: 'provider_local_database'; partialHistory: true
    qualifications: string[]; firstRetainedAt: string | null; lastRetainedAt: string | null; populatedDays: number
  }
  pricing: { revision: string; observedOn: string; digest: string; basis: 'standard_global_api_equivalent' | 'models_dev_catalog' }
  totals: Aggregate
  providers: { provider: Provider; label: string; totals: Aggregate; models: { modelId: string; totals: Aggregate }[] }[]
  trend: { range: 'last30days'; startAt: string; endAt: string; days: { date: string; startAt: string; endAt: string; selected: boolean; totals: Aggregate }[] }
}
export type ActivityResponse = { status: Status; activity: Group<ActivityData> }
export function decodeActivity(text: string): ActivityResponse {
  const result: ActivityResponse = JSON.parse(text)
  if (result.status.apiMajor !== 1) throw new Error('Update Tally: this API version is incompatible.')
  return result
}
const compact = new Intl.NumberFormat('en-US', { notation: 'compact', maximumFractionDigits: 1 })
export const compactTokens = (count: number) => compact.format(count)
export const usd = (value: string) => {
  const amount = Number(value)
  return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: amount >= 100 ? 0 : 2 }).format(amount)
}
export const tokenLabel = (value: Aggregate) => value.rows === 0 ? 'no activity' : value.tokens === null ? 'usage missing' : `${compactTokens(value.tokens.total)} tokens`
// Partial bounds cover priced components only, so the lower bound is the only honest claim about all activity.
export function apiValue(value: Aggregate): string | null {
  const { status, lower, upper } = value.estimate
  if (status === 'empty') return null
  if (lower === null || upper === null) return 'Not priced'
  if (status === 'partial') return `at least ${usd(lower)}`
  return lower === upper ? usd(lower) : `${usd(lower)} to ${usd(upper)}`
}
export const activityRanges = [{ value: 'today', label: 'Today' }, { value: 'yesterday', label: 'Yesterday' }, { value: 'last30days', label: 'Last 30 days' }] satisfies { value: ActivityRange; label: string }[]
