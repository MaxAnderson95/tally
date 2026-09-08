import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { once } from 'node:events'
import { z } from 'zod'
import { createTally, defaultBaseURL } from '../src/tally.ts'
import { Input, Command, Result, AccountsResponse, ActivityResponse, RefreshResponse } from '../src/contract.ts'
import type { TallyInput } from '../src/contract.ts'
import plugin from '../src/index.ts'

const fixture = (name: string): unknown => JSON.parse(readFileSync(new URL(`../../Tests/TallyTests/Fixtures/${name}.json`, import.meta.url), 'utf8'))
const accounts = AccountsResponse.parse(fixture('accounts'))
const activity = ActivityResponse.parse(fixture('activity'))
const refresh = RefreshResponse.parse(fixture('refresh'))
const detail = { status: accounts.status, account: accounts.accounts[0] }

async function serve(run: (baseURL: string, requests: { path: string; method: string; body: string; contentType?: string }[]) => Promise<void>, reply?: (path: string) => { status?: number; data: unknown }) {
  const requests: { path: string; method: string; body: string; contentType?: string }[] = []
  const server = createServer(async (req, res) => {
    let body = ''
    for await (const chunk of req) body += chunk
    const path = req.url ?? ''
    requests.push({ path, method: req.method ?? '', body, contentType: req.headers['content-type'] })
    const response = reply?.(path) ?? { data: path === '/api/v1/status' ? accounts.status : path === '/api/v1/accounts' ? accounts : path.startsWith('/api/v1/accounts/') ? detail : path.startsWith('/api/v1/activity') ? activity : refresh }
    res.writeHead(response.status ?? 200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify(response.data))
  })
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  const address = server.address()
  assert(address && typeof address !== 'string')
  try { await run(`http://127.0.0.1:${address.port}`, requests) }
  finally { await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve())) }
}

test('each query maps to its route and concrete structured DTO, preserving stale and unknown readings', async () => {
  await serve(async (baseURL, requests) => {
    const tally = createTally({ baseURL })
    const cases: [TallyInput, string, unknown][] = [
      [{ action: 'status' }, '/api/v1/status', accounts.status],
      [{ action: 'accounts' }, '/api/v1/accounts', accounts],
      [{ action: 'accounts', accountId: 'opaque /?#' }, '/api/v1/accounts/opaque%20%2F%3F%23', detail],
      [{ action: 'activity' }, '/api/v1/activity', activity],
      ...(['today', 'yesterday', 'last30days'] as const).map(range => [{ action: 'activity' as const, range }, `/api/v1/activity?range=${range}`, activity] satisfies [TallyInput, string, unknown]),
    ]
    for (const [input, path, expected] of cases) {
      const result = await tally.execute(input)
      assert.deepEqual(result, { output: { ok: true, action: input.action, data: expected } })
      assert(Result.safeParse(result.output).success)
      assert.equal(requests.at(-1)?.path, path)
    }
    assert(requests.every(request => request.method === 'GET' && request.body === ''))
    assert.equal(requests.length, cases.length)
    const windows = accounts.accounts[0].groups.quotas.data!.windows
    assert.equal(windows[0].stale, true)
    assert.equal(windows[1].remainingPercent, null)
    assert.equal(windows[2].usedPercent, 0)
  })
})

test('refresh verifies major first and preserves all scheduling states, omitted/all, activity-only and explicit IDs', async () => {
  await serve(async (baseURL, requests) => {
    for (const accountIds of [undefined, [], ['one', 'one', 'two']]) {
      const result = await createTally({ baseURL }).execute({ action: 'refresh', ...(accountIds === undefined ? {} : { accountIds }) })
      assert.deepEqual(result.output, { ok: true, action: 'refresh', data: refresh })
      assert.equal(requests.at(-2)?.path, '/api/v1/status')
      assert.deepEqual(requests.at(-1), { path: '/api/v1/refresh', method: 'POST', contentType: 'application/json', body: JSON.stringify(accountIds === undefined ? {} : { accountIds }) })
    }
    assert.equal(requests.length, 6)
  })
})

test('command schema rejects invalid actions, IDs, ranges, nulls and unrelated action fields', () => {
  for (const value of [null, {}, { action: 'redeem' }, { action: 'status', range: 'today' }, { action: 'accounts', accountId: '' }, { action: 'accounts', accountId: null }, { action: 'activity', range: 'week' }, { action: 'refresh', accountIds: null }, { action: 'refresh', accountIds: [3] }, { action: 'refresh', accountIds: [''] }]) {
    assert.equal(Command.safeParse(value).success, false, JSON.stringify(value))
  }
})

test('executor declines a malformed known action without making a request', async () => {
  await serve(async (baseURL, requests) => {
    for (const input of [{ action: 'accounts', accountId: '' }, { action: 'status', range: 'today' }, { action: 'accounts', accountIds: [] }, { action: 'activity', accountId: 'one' }, { action: 'refresh', range: 'today' }] satisfies TallyInput[]) {
      const result = await createTally({ baseURL }).execute(input)
      assert.equal(result.output.ok, false)
      if (!result.output.ok) assert.equal(result.output.error.code, 'invalid_request')
    }
    assert.equal(requests.length, 0)
  })
})

test('unavailable app and invalid configuration return structured faults', async () => {
  let closedURL = ''
  await serve(async baseURL => { closedURL = baseURL })
  const result = await createTally({ baseURL: closedURL }).execute({ action: 'status' })
  assert.equal(result.output.ok, false)
  if (!result.output.ok) assert.equal(result.output.error.code, 'app_unavailable')
  assert(Result.safeParse(result.output).success)
  for (const baseURL of ['bad', 'ftp://localhost', 'http://user:secret@localhost', 'http://localhost/api', 'http://localhost/?q=1']) {
    const result = await createTally({ baseURL }).execute({ action: 'status' })
    assert.equal(result.output.ok, false)
    if (!result.output.ok) assert.equal(result.output.error.code, 'invalid_configuration')
  }
  assert.equal(defaultBaseURL, 'http://127.0.0.1:7483')
})

test('major mismatch requests an update and prevents refresh; app release equality is unnecessary', async () => {
  await serve(async (baseURL, requests) => {
    for (const action of ['status', 'accounts', 'activity', 'refresh'] as const) {
      const result = await createTally({ baseURL }).execute({ action })
      assert.equal(result.output.ok, false)
      if (!result.output.ok) {
        assert.equal(result.output.error.code, 'incompatible_api')
        assert.match(result.output.error.message, /Update/)
      }
    }
    assert(requests.every(request => request.method === 'GET'))
  }, path => ({ data: path === '/api/v1/status' ? { ...accounts.status, apiMajor: 2 } : { status: { ...accounts.status, apiMajor: 2 } } }))
})

test('additive v1 fields survive at every level and partial activity coverage is not collapsed', async () => {
  const response = ActivityResponse.parse({ status: accounts.status, activity: { ...activity.activity, data: fixture('activity-pricing') } })
  response.futureField = 'retained'
  response.status.appBuild = '99.123.456'
  response.status.futureStatus = 12
  response.activity.stale = true
  response.activity.futureGroup = { supported: true }
  assert(response.activity.data)
  response.activity.data.source.partialHistory = true
  assert.equal(response.activity.data.totals.estimate.status, 'partial')
  assert.equal(response.activity.data.totals.estimate.coverage.unpricedComponents.cacheWrite, 1000)
  await serve(async baseURL => {
    const result = await createTally({ baseURL }).execute({ action: 'activity' })
    assert.deepEqual(result.output, { ok: true, action: 'activity', data: response })
    assert.deepEqual(Result.parse(result.output), result.output)
  }, () => ({ data: response }))
})

test('account details retain current Swift credit DTOs, unknown expiry, null applicability and reference money', async () => {
  const readings = z.object({ quotas: z.unknown(), balances: z.unknown(), details: z.unknown() }).parse(fixture('openai-readings'))
  const account = accounts.accounts[0]
  const response = { status: accounts.status, account: { ...account, provider: 'openai', service: 'chatgpt-subscription', groups: {
    ...account.groups,
    quotas: { ...account.groups.quotas, data: readings.quotas },
    balances: { ...account.groups.balances, data: readings.balances },
    resetDetails: { ...account.groups.resetDetails, data: readings.details },
  } } }
  await serve(async baseURL => {
    const result = await createTally({ baseURL }).execute({ action: 'accounts', accountId: account.id })
    assert.deepEqual(result.output, { ok: true, action: 'accounts', data: response })
    assert(Result.safeParse(result.output).success)
  }, () => ({ data: response }))
})

test('HTTP faults preserve retry and blocking fields; malformed success is a structured failure', async () => {
  const fault = { code: 'inventory_unavailable', message: 'Retained inventory is stale.', retryAt: '2030-09-08T00:00:00Z', blockingOperationId: 'opaque-operation', future: true }
  await serve(async baseURL => {
    assert.deepEqual((await createTally({ baseURL }).execute({ action: 'accounts' })).output, { ok: false, action: 'accounts', error: fault })
  }, () => ({ status: 503, data: { error: fault } }))
  await serve(async baseURL => {
    const result = await createTally({ baseURL }).execute({ action: 'accounts' })
    assert.equal(result.output.ok, false)
    if (!result.output.ok) assert.equal(result.output.error.code, 'invalid_response')
  }, () => ({ data: { status: accounts.status, accounts: [{ id: 'incomplete' }] } }))
})

test('the output schema rejects success DTOs paired with the wrong action', () => {
  for (const [action, data] of [['status', accounts], ['accounts', accounts.status], ['activity', refresh], ['refresh', activity]]) {
    assert.equal(Result.safeParse({ ok: true, action, data }).success, false)
  }
  const schema = z.toJSONSchema(Result)
  assert(schema.anyOf && schema.anyOf.length === 5)
  const inputSchema = z.toJSONSchema(createTally().input, { target: 'draft-2020-12', io: 'input' })
  assert.equal(inputSchema.type, 'object')
  for (const keyword of ['anyOf', 'oneOf', 'allOf']) assert.equal(keyword in inputSchema, false)
  assert.deepEqual(Input.parse({ action: 'activity', range: 'today' }), { action: 'activity', range: 'today' })
  assert.equal(plugin.id, 'tally')
})
