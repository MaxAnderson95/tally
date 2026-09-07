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
  pricing: { revision: string; observedOn: string; digest: string; basis: 'standard_global_api_equivalent' }
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
export const tokenLabel = (value: Aggregate) => value.rows === 0 ? 'No recorded activity' : value.tokens === null ? 'Usage missing' : `${value.tokens.total.toLocaleString()} recorded tokens`
export const costLabel = (value: Aggregate) => value.rows === 0 ? 'Recorded cost: no recorded activity' : value.recordedCost.amount === null ? 'Recorded cost unavailable' : value.recordedCost.amount === '0' ? 'Recorded $0; pricing provenance unknown' : `Recorded $${value.recordedCost.amount} USD`
export function estimateLabel(value: Estimate): string {
  if (value.status === 'empty') return 'API-equivalent estimate: No recorded activity'
  if (value.lower === null || value.upper === null) return 'API-equivalent estimate: Unpriced'
  const amount = value.lower === value.upper ? `$${value.lower}` : `$${value.lower} to $${value.upper}`
  return `API-equivalent ${value.status === 'partial' ? 'partial subtotal' : 'estimate'}: ${amount} USD`
}
export function estimateQualification(value: Estimate): string {
  switch (value.status) {
    case 'partial': return 'Incomplete: bounds cover priced components only; the upper value does not bound all activity.'
    case 'range': return 'Bounded reference: Anthropic writes use 5m/1h alternatives; Go DeepSeek uses off-peak/peak alternatives.'
    case 'unpriced': return 'No verified amount for these records; recorded cost is separate.'
    default: return 'Dated standard/global reference-token value, not a bill, subscription charge, quota debit or savings.'
  }
}
export const activityRanges = [{ value: 'today', label: 'Today' }, { value: 'yesterday', label: 'Yesterday' }, { value: 'last30days', label: 'Last 30 days' }] satisfies { value: ActivityRange; label: string }[]
