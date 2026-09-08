import { z } from 'zod'
import { Input, Command, Result, Status, AccountsResponse, AccountResponse, ActivityResponse, RefreshResponse, Redemption, Fault } from './contract.ts'
import type { TallyInput, TallyResult } from './contract.ts'

export const defaultBaseURL = 'http://127.0.0.1:7483'
const Options = z.object({ baseURL: z.url().default(defaultBaseURL) })

export function createTally(options: unknown = {}) {
  const parsed = Options.safeParse(options)
  const base = parsed.success ? new URL(parsed.data.baseURL) : undefined
  const validBase = base && ['http:', 'https:'].includes(base.protocol) && !base.username && !base.password && !base.search && !base.hash && base.pathname === '/'
  const fault = (code: string, message: string): z.infer<typeof Fault> => ({ code, message, retryAt: null, blockingOperationId: null })

  async function request(path: string, body?: object): Promise<unknown> {
    let response: Response
    try {
      response = await fetch(new URL(`/api/v1${path}`, base), {
        method: body === undefined ? 'GET' : 'POST',
        ...(body === undefined ? {} : { headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }),
        signal: AbortSignal.timeout(15_000), redirect: 'error',
      })
    } catch {
      throw fault('app_unavailable', 'Cannot reach Tally. Start the app on its Mac and check the companion baseURL and network connection.')
    }
    let data: unknown
    try { data = await response.json() } catch {
      throw fault('invalid_response', 'Tally did not return JSON. Check the baseURL and update the app or companion if needed.')
    }
    if (!response.ok) {
      const error = z.object({ error: Fault }).safeParse(data)
      throw error.success ? error.data.error : fault('http_error', `Tally returned HTTP ${response.status} without a compatible fault.`)
    }
    return data
  }

  function decode<T extends z.ZodType>(schema: T, data: unknown): z.infer<T> {
    const result = schema.safeParse(data)
    if (!result.success) throw fault('invalid_response', 'Tally returned an incompatible response shape. Update the app or companion.')
    return result.data
  }

  function status(data: unknown) {
    const version = z.object({ apiMajor: z.number().int() }).safeParse(data)
    if (version.success && version.data.apiMajor !== 1) {
      throw fault('incompatible_api', `Tally API major ${version.data.apiMajor} is incompatible with this companion (major 1). Update the app or companion; release numbers need not match.`)
    }
    return decode(Status, data)
  }

  async function query(raw: TallyInput): Promise<TallyResult> {
    try {
      if (!validBase) throw fault('invalid_configuration', 'Set baseURL to the Tally HTTP(S) origin, with no credentials, path, query, or fragment.')
      const validated = Command.safeParse(raw)
      if (!validated.success) throw fault('invalid_request', 'Use an action with its documented fields. Account and credit IDs must be nonempty; reset actions require the original operation UUID. Unrelated fields are not accepted.')
      const input = validated.data
      if (input.action === 'redeem' || input.action === 'redemption' || input.action === 'acknowledge') {
        status(await request('/status'))
        const path = `/redemptions/${encodeURIComponent(input.operationId)}`
        if (input.action === 'redemption') return { ok: true, action: input.action, data: decode(Redemption, await request(path)) }
        try {
          const data = input.action === 'redeem'
            ? await request(`/accounts/${encodeURIComponent(input.accountId)}/redemptions`, { operationId: input.operationId, ...(input.creditId === undefined ? {} : { creditId: input.creditId }) })
            : await request(`${path}/acknowledge`, {})
          return { ok: true, action: input.action, data: decode(Redemption, data) }
        } catch (error) {
          const known = Fault.safeParse(error)
          if (known.success && !['app_unavailable', 'invalid_response', 'http_error'].includes(known.data.code)) throw error
          // A lost mutation response is not evidence of failure. Only read the original operation.
          try {
            return { ok: true, action: input.action, data: decode(Redemption, await request(path)) }
          } catch {
            throw fault('operation_response_unknown', `The ${input.action} response was lost or incompatible; its outcome is uncertain. Original operation UUID: ${input.operationId}. Read it with redemption using that UUID. Do not resend, generate a replacement UUID, or infer success from changed usage. Ask the user before acknowledgement or a new operation.`)
          }
        }
      }
      // Refresh has no status envelope, so verify compatibility before scheduling any work.
      if (input.action === 'status' || input.action === 'refresh') {
        const current = status(await request('/status'))
        if (input.action === 'status') return { ok: true, action: input.action, data: current }
        return { ok: true, action: input.action, data: decode(RefreshResponse, await request('/refresh', input.accountIds === undefined ? {} : { accountIds: input.accountIds })) }
      }
      if (input.action === 'accounts') {
        const data = await request(input.accountId === undefined ? '/accounts' : `/accounts/${encodeURIComponent(input.accountId)}`)
        status(decode(z.object({ status: z.unknown() }), data).status)
        return { ok: true, action: input.action, data: input.accountId === undefined ? decode(AccountsResponse, data) : decode(AccountResponse, data) }
      }
      const data = await request(`/activity${input.range === undefined ? '' : `?range=${input.range}`}`)
      status(decode(z.object({ status: z.unknown() }), data).status)
      return { ok: true, action: input.action, data: decode(ActivityResponse, data) }
    } catch (error) {
      const known = Fault.safeParse(error)
      return { ok: false, action: raw.action, error: known.success ? known.data : fault('invalid_response', 'The Tally query failed without a compatible result.') }
    }
  }

  return {
    name: 'tally',
    description: 'Query Tally periodically while working to check remaining subscription usage, freshness, reset times and pacing. status checks the app; accounts lists all Accounts or reads an explicit opaque accountId; activity reads retained provider-level OpenCode activity (today by default); refresh schedules reads without waiting for collection. Queries are model-directed. Every redeem requires a specific explicit user request to consume one banked reset for the named Account; standing permission, low usage, and keep working do not qualify. Resolve names through accounts and ask the user to clarify ambiguous names to an opaque accountId. Never select an active or fallback Account implicitly. Omit creditId for app selection or supply the specifically requested credit. Nullable applicability means not reported, not zero or ineligible; the provider decides which windows reset. Use one operation UUID per explicitly authorized redemption and retain it. Never automatically retry a mutation or generate a replacement UUID after response loss. The companion attempts one read of that original operation after response loss; if unresolved it reports uncertainty and the original UUID. Use redemption with that UUID for further progress reads. Pending is accepted, not confirmed; return promptly and query progress separately. Unknown requires asking the user before acknowledgement or a new operation. Every acknowledge also requires specific explicit user instruction; it releases the block without retrying or changing unknown to confirmed. Tally trusts this local client authorization claim and cannot inspect the conversation. Confirmed outcomes remain confirmed independently of failed usage refresh; do not infer reset effects or success from changed readings. Keep operation IDs, result URLs, acknowledgement requirements and structured faults visible. Null is unknown, not zero. Keep stale readings, partial history and pricing coverage visible. Inventory and activity belong to the Mac running Tally. Activity and API-equivalent estimates are not measured quota consumption or subscription charges.',
    input: Input,
    output: Result,
    options: { codemode: false as const },
    execute: async (input: TallyInput) => ({ output: await query(input) }),
  }
}
