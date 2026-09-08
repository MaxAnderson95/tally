import { z } from 'zod'

const text = z.string()
const number = z.number()
const nullableText = text.nullable()
const nullableNumber = number.nullable()
const flag = z.boolean()
// Loose response objects retain additive v1 fields, including inside reading groups.
const object = z.looseObject
export const Fault = object({ code: text, message: text, retryAt: nullableText, blockingOperationId: nullableText })
const group = <T extends z.ZodType>(data: T) => object({
  data: data.nullable(), observedAt: nullableText, lastAttemptAt: nullableText,
  stale: flag, refreshing: flag, nextAttemptAt: nullableText, error: Fault.nullable(),
})
const Provider = z.enum(['anthropic', 'openai', 'opencode-go', 'xai'])
export const Range = z.enum(['today', 'yesterday', 'last30days'])
const Money = object({
  amount: text, currency: text, provenance: z.enum(['provider', 'reference_conversion']),
  source: object({ amount: text, unit: text, exponent: nullableNumber }),
})
const QuotaWindow = object({
  id: text, label: text, scope: z.enum(['account', 'model', 'other']), scopeNote: nullableText, modelId: nullableText,
  cadence: z.enum(['rolling', 'weekly', 'monthly', 'other']), durationSeconds: nullableNumber,
  durationSource: z.enum(['provider', 'verified_mapping', 'unknown']), usedPercent: nullableNumber,
  remainingPercent: nullableNumber, resetAt: nullableText, resetState: z.enum(['scheduled', 'passed', 'not_started', 'unknown']),
  stale: flag, displayInOverview: flag,
  pacing: object({ projectedUsedPercent: number, sparePercent: number, runOutAt: nullableText, runOutReason: nullableText }).nullable(),
  pacingUnavailableReason: nullableText,
})
const ExtraUsage = object({
  enabled: flag.nullable(), used: Money.nullable(), limit: Money.nullable(), remaining: Money.nullable(),
  remainingPercent: nullableNumber, periodLabel: nullableText, presentation: z.enum(['off', 'used_only', 'bounded', 'unavailable']),
})
const Balance = object({ unit: text, quantity: nullableText, money: Money.nullable(), referenceValue: Money.nullable(), unlimited: flag.nullable() })
const ResetSummary = object({ availableCount: nullableNumber, applicableAvailableCount: nullableNumber, source: z.enum(['usage', 'credit_details']) })
const Credit = object({
  id: text, type: nullableText, status: nullableText, available: flag.nullable(), title: nullableText,
  description: nullableText, grantedAt: nullableText,
  expiry: z.union([object({ kind: z.literal('at'), at: text }), object({ kind: z.enum(['none', 'unknown']), at: z.null() })]),
})
export const Account = object({
  id: text, provider: Provider, service: z.enum(['claude-subscription', 'chatgpt-subscription', 'opencode-go', 'grok-subscription']),
  name: text, pinned: flag, pinOrder: nullableNumber, identityColorIndex: number,
  pin: object({ lines: z.array(object({ windowId: text, label: text, remainingPercent: nullableNumber, stale: flag })), warning: flag }),
  groups: object({
    plan: group(object({ name: text })), quotas: group(object({ windows: z.array(QuotaWindow) })),
    extraUsage: group(ExtraUsage), balances: group(object({ items: z.array(Balance) })),
    resetSummary: group(ResetSummary), resetDetails: group(object({ credits: z.array(Credit), summary: ResetSummary.optional() })),
  }),
  command: object({ blockingOperationId: nullableText, state: z.enum(['pending', 'unknown']).nullable(), acknowledgementRequired: flag }),
})
export const Status = object({
  apiMajor: z.literal(1), appBuild: text, serverTime: text, timezone: text, owner: z.enum(['ready', 'shutting_down']),
  inventory: group(object({ count: number, namespaceId: text })), recoveryStorage: object({ available: flag, error: Fault.nullable() }),
})
export const AccountsResponse = object({ status: Status, accounts: z.array(Account) })
export const AccountResponse = object({ status: Status, account: Account })
const Schedule = object({ state: z.enum(['started', 'joined', 'deferred', 'blocked']), nextAttemptAt: nullableText, reason: Fault.nullable() })
export const RefreshResponse = object({ accounts: z.array(object({ accountId: text, schedule: Schedule })), activity: Schedule })
const Tokens = object({ input: number, output: number, reasoning: number, cacheRead: number, cacheWrite: number, total: number })
const Estimate = object({
  status: z.enum(['scalar', 'range', 'partial', 'unpriced', 'empty']), currency: z.literal('USD'), lower: nullableText, upper: nullableText,
  coverage: object({ fullyPricedRows: number, boundedRows: number, partiallyPricedRows: number, unpricedRows: number, missingUsageRows: number, pricedComponents: Tokens, unpricedComponents: Tokens }),
  exclusions: z.array(object({ provider: Provider, modelId: text, reason: text, rows: number, tokens: Tokens.nullable() })),
})
const Aggregate = object({
  rows: number, missingUsageRows: number, tokens: Tokens.nullable(),
  recordedCost: object({ amount: nullableText, currency: z.literal('USD'), rowsWithCost: number, missingCostRows: number, ambiguousZeroRows: number }),
  estimate: Estimate,
})
export const ActivityResponse = object({
  status: Status,
  activity: group(object({
    range: Range, startAt: text, endAt: text, timezone: text,
    source: object({ namespaceId: text, schemaRevision: text, attribution: z.literal('provider_local_database'), partialHistory: z.literal(true), qualifications: z.array(text), firstRetainedAt: nullableText, lastRetainedAt: nullableText, populatedDays: number }),
    pricing: object({ revision: text, observedOn: text, digest: text, basis: z.literal('standard_global_api_equivalent') }),
    totals: Aggregate,
    providers: z.array(object({ provider: Provider, label: text, totals: Aggregate, models: z.array(object({ modelId: text, totals: Aggregate })) })),
    trend: object({ range: z.literal('last30days'), startAt: text, endAt: text, days: z.array(object({ date: text, startAt: text, endAt: text, selected: flag, totals: Aggregate })) }),
  })),
})

const id = text.min(1)
export const Redemption = object({
  operationId: text, accountId: text, accountName: text, requestedCreditId: nullableText, selectedCreditId: nullableText,
  createdAt: text, updatedAt: text, state: z.enum(['pending', 'confirmed', 'nothing_to_reset', 'no_credit', 'failed', 'unknown']),
  providerResult: object({ code: text, windowsReset: nullableNumber }).nullable(), error: Fault.nullable(),
  acknowledgementRequired: flag, acknowledgedAt: nullableText, resultUrl: text,
})
const operationId = z.string().regex(/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/, 'Use the original operation UUID')
// Anthropic requires an object root; action-specific field pairing is checked during execution.
export const Input = z.strictObject({
  action: z.enum(['status', 'accounts', 'activity', 'refresh', 'redeem', 'redemption', 'acknowledge']),
  accountId: id.optional(), range: Range.optional(), accountIds: z.array(id).optional(),
  operationId: operationId.optional(), creditId: id.optional(),
})
export const Command = z.discriminatedUnion('action', [
  z.strictObject({ action: z.literal('status') }),
  z.strictObject({ action: z.literal('accounts'), accountId: id.optional() }),
  z.strictObject({ action: z.literal('activity'), range: Range.optional() }),
  z.strictObject({ action: z.literal('refresh'), accountIds: z.array(id).optional() }),
  z.strictObject({ action: z.literal('redeem'), accountId: id, operationId, creditId: id.optional() }),
  z.strictObject({ action: z.literal('redemption'), operationId }),
  z.strictObject({ action: z.literal('acknowledge'), operationId }),
])
export type TallyInput = z.infer<typeof Input>
export const Result = z.union([
  object({ ok: z.literal(true), action: z.literal('status'), data: Status }),
  object({ ok: z.literal(true), action: z.literal('accounts'), data: z.union([AccountsResponse, AccountResponse]) }),
  object({ ok: z.literal(true), action: z.literal('activity'), data: ActivityResponse }),
  object({ ok: z.literal(true), action: z.literal('refresh'), data: RefreshResponse }),
  object({ ok: z.literal(true), action: z.literal('redeem'), data: Redemption }),
  object({ ok: z.literal(true), action: z.literal('redemption'), data: Redemption }),
  object({ ok: z.literal(true), action: z.literal('acknowledge'), data: Redemption }),
  object({ ok: z.literal(false), action: z.enum(['status', 'accounts', 'activity', 'refresh', 'redeem', 'redemption', 'acknowledge']), error: Fault }),
])
export type TallyResult = z.infer<typeof Result>
