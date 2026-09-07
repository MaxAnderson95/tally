import { z } from 'zod'
import { Input, Result, Status, AccountsResponse, AccountResponse, ActivityResponse, RefreshResponse, Fault } from './contract.ts'
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

  async function query(input: TallyInput): Promise<TallyResult> {
    try {
      if (!validBase) throw fault('invalid_configuration', 'Set baseURL to the Tally HTTP(S) origin, with no credentials, path, query, or fragment.')
      const validated = Input.safeParse(input)
      if (!validated.success) throw fault('invalid_request', 'Use status, accounts with optional accountId, activity with optional today/yesterday/last30days range, or refresh with optional accountIds. IDs must be nonempty strings; unrelated fields are not accepted.')
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
      return { ok: false, action: input.action, error: known.success ? known.data : fault('invalid_response', 'The Tally query failed without a compatible result.') }
    }
  }

  return {
    name: 'tally',
    description: 'Query Tally periodically while working to check remaining subscription usage, freshness, reset times and pacing. status checks the app; accounts lists all Accounts or reads an explicit opaque accountId; activity reads retained provider-level OpenCode activity (today by default); refresh schedules reads and returns started/joined/deferred/blocked state without waiting for collection. Null is unknown, not zero. Keep stale readings, partial history and pricing coverage visible. Inventory and activity belong to the Mac running Tally, regardless of this OpenCode instance. Activity and API-equivalent estimates are not measured quota consumption or subscription charges.',
    input: Input,
    output: Result,
    options: { codemode: false as const },
    execute: async (input: TallyInput) => ({ output: await query(input) }),
  }
}
