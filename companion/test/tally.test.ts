import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { once } from 'node:events'
import { z } from 'zod'
import { createTally, defaultBaseURL } from '../src/tally.ts'
import { Input, Command, Result, AccountsResponse, ActivityResponse, RefreshResponse, Redemption } from '../src/contract.ts'
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
  assert(schema.anyOf && schema.anyOf.length === 8)
  const inputSchema = z.toJSONSchema(createTally().input, { target: 'draft-2020-12', io: 'input' })
  assert.equal(inputSchema.type, 'object')
  for (const keyword of ['anyOf', 'oneOf', 'allOf']) assert.equal(keyword in inputSchema, false)
  assert.deepEqual(Input.parse({ action: 'activity', range: 'today' }), { action: 'activity', range: 'today' })
  assert.equal(plugin.id, 'tally')
})

const operations = z.array(Redemption).parse(fixture('redemptions'))
const operationId = operations[0].operationId

test('reset actions map exact requests, preserve pending and duplicate UUIDs, and pair concrete outputs', async () => {
  await serve(async (baseURL, requests) => {
    const tally = createTally({ baseURL })
    const input = { action: 'redeem', accountId: 'opaque /?#', operationId } as const
    for (const creditId of [undefined, undefined, 'credit-a']) {
      const result = await tally.execute({ ...input, ...(creditId === undefined ? {} : { creditId }) })
      assert.deepEqual(result.output, { ok: true, action: 'redeem', data: operations[0] })
      assert.deepEqual(requests.at(-1), { path: '/api/v1/accounts/opaque%20%2F%3F%23/redemptions', method: 'POST', contentType: 'application/json', body: JSON.stringify({ operationId, ...(creditId === undefined ? {} : { creditId }) }) })
      assert(Result.safeParse(result.output).success)
    }
    assert.equal(requests.length, 6)
    for (const action of ['redemption', 'acknowledge'] as const) {
      const result = await tally.execute({ action, operationId })
      assert.equal(result.output.ok, true)
      assert(Result.safeParse(result.output).success)
      assert.equal(requests.at(-1)?.path, `/api/v1/redemptions/${operationId}${action === 'acknowledge' ? '/acknowledge' : ''}`)
      assert.equal(requests.at(-1)?.body, action === 'acknowledge' ? '{}' : '')
      assert.equal(Result.safeParse({ ok: true, action, data: refresh }).success, false)
    }
  }, path => ({ status: path.endsWith('/redemptions') ? 202 : 200, data: path === '/api/v1/status' ? accounts.status : operations[0] }))
})

test('all durable states and acknowledgement remain independent of usage refresh', async () => {
  for (const data of [...operations, ...(['nothing_to_reset', 'no_credit', 'failed'] as const).map(state => ({ ...operations[0], state }))]) {
    await serve(async (baseURL, requests) => {
      const result = await createTally({ baseURL }).execute({ action: data.acknowledgedAt ? 'acknowledge' : 'redemption', operationId: data.operationId })
      assert.deepEqual(result.output, { ok: true, action: data.acknowledgedAt ? 'acknowledge' : 'redemption', data })
      assert.equal(requests.length, 2)
      assert(!requests.some(request => request.path.includes('refresh')))
    }, path => ({ data: path === '/api/v1/status' ? accounts.status : path.includes('refresh') ? { error: { code: 'collection_failed' } } : data }))
  }
})

test('reset HTTP conflicts and blocks preserve the original structured fault without retry or lookup', async () => {
  for (const code of ['operation_conflict', 'account_blocked', 'recovery_storage_unavailable']) {
    const error = { code, message: 'Cannot accept.', retryAt: '2030-09-08T00:00:00Z', blockingOperationId: operationId }
    await serve(async (baseURL, requests) => {
      const result = await createTally({ baseURL }).execute({ action: 'redeem', accountId: 'opaque', operationId })
      assert.deepEqual(result.output, { ok: false, action: 'redeem', error })
      assert.equal(requests.length, 2)
    }, path => path === '/api/v1/status' ? { data: accounts.status } : { status: code === 'recovery_storage_unavailable' ? 503 : 409, data: { error } })
  }
})

test('lost mutation responses read only the original UUID; missing lookup retains uncertainty', async () => {
  for (const action of ['redeem', 'acknowledge'] as const) {
    for (const recovered of [true, false]) {
      const requests: { method: string; path: string; body: string }[] = []
      const server = createServer(async (req, res) => {
        let body = ''
        for await (const chunk of req) body += chunk
        requests.push({ method: req.method!, path: req.url!, body })
        if (req.method === 'POST') { req.socket.destroy(); return }
        const data = req.url === '/api/v1/status' ? accounts.status : recovered ? operations[1] : { error: { code: 'operation_not_found', message: 'Not found', retryAt: null, blockingOperationId: null } }
        res.writeHead(req.url !== '/api/v1/status' && !recovered ? 404 : 200, { 'Content-Type': 'application/json' })
        res.end(JSON.stringify(data))
      })
      server.listen(0, '127.0.0.1')
      await once(server, 'listening')
      const address = server.address()
      assert(address && typeof address !== 'string')
      try {
        const tally = createTally({ baseURL: `http://127.0.0.1:${address.port}` })
        const result = await tally.execute(action === 'redeem' ? { action, accountId: 'opaque', operationId } : { action, operationId })
        assert.equal(result.output.ok, recovered)
        if (result.output.ok) {
          assert.deepEqual(result.output.data, operations[1])
          if (action === 'acknowledge') {
            assert.equal(result.output.data.acknowledgedAt, null)
            assert.equal(result.output.data.acknowledgementRequired, true)
            assert.match(tally.description, /null acknowledgedAt means acknowledgement is not confirmed by this read/)
          }
        }
        else {
          assert.equal(result.output.error.code, 'operation_response_unknown')
          assert(result.output.error.message.includes(operationId))
          assert.match(result.output.error.message, /uncertain/)
          assert(result.output.error.message.includes(`${action}: app_unavailable, lookup: operation_not_found`))
        }
        assert.equal(requests.length, 3)
        assert.equal(requests.filter(request => request.method === 'POST').length, 1)
        assert.equal(requests.at(-1)?.path, `/api/v1/redemptions/${operationId}`)
      } finally { await new Promise<void>(resolve => server.close(() => resolve())) }
    }
  }
})

test('reset inputs reject invalid UUIDs and app/version failure prevents mutation', async () => {
  const schema = z.toJSONSchema(Input)
  const patterns = schema.anyOf?.flatMap(variant => typeof variant !== 'boolean' && variant.properties?.operationId && typeof variant.properties.operationId !== 'boolean' ? [variant.properties.operationId.pattern!] : [])
  assert.equal(patterns?.length, 3)
  for (const pattern of patterns!) {
    assert(new RegExp(pattern).test(operationId))
    assert(new RegExp(pattern).test(operationId.toLowerCase()))
    assert.equal(new RegExp(pattern).test('replacement'), false)
  }
  for (const action of ['redeem', 'redemption', 'acknowledge'] as const) {
    for (const uuid of [operationId, operationId.toLowerCase()]) {
      assert(Input.safeParse(action === 'redeem' ? { action, accountId: 'opaque', operationId: uuid } : { action, operationId: uuid }).success)
    }
    assert.equal(Input.safeParse({ action, operationId: 'replacement' }).success, false)
    await serve(async (baseURL, requests) => {
      const result = await createTally({ baseURL }).execute(action === 'redeem' ? { action, accountId: 'opaque', operationId } : { action, operationId })
      assert.equal(result.output.ok, false)
      if (!result.output.ok) assert.equal(result.output.error.code, 'incompatible_api')
      assert.equal(requests.length, 1)
      assert.equal(requests[0].method, 'GET')
    }, () => ({ data: { ...accounts.status, apiMajor: 2 } }))
  }
  let closedURL = ''
  await serve(async baseURL => { closedURL = baseURL })
  const result = await createTally({ baseURL: closedURL }).execute({ action: 'redeem', accountId: 'opaque', operationId })
  assert.equal(result.output.ok, false)
  if (!result.output.ok) assert.equal(result.output.error.code, 'app_unavailable')
})
