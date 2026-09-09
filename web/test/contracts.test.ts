import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { runInNewContext } from 'node:vm'
import { balanceLabel, creditExpiryLabel, resetCountLabel, decodeAccounts, groupIsStale, moneyLabel, overviewWindows, percentage, resetLabel, scheduleLabel, earlyLimitDate, countdown, quotaWarning, type QuotaWindow, type Balance, type Credit, type ResetSummary, type ExtraUsage, type RefreshResponse } from '../src/api.ts'
import type { Redemption } from '../src/api.ts'
import { creditUsable, RedemptionClient, redemptionLabel } from '../src/redemptions.ts'

test('home-screen launches fall back offline while API reads and commands bypass the service worker', async () => {
  type FetchEvent = { request: { url: string; method: string; mode: string }; respondWith: (response: Promise<Response>) => void }
  let handleFetch: (event: FetchEvent) => void = () => assert.fail('Missing fetch handler')
  let reachable = true
  let status = 200
  runInNewContext(readFileSync(new URL('../../assets/web/sw.js', import.meta.url), 'utf8'), {
    URL, AbortSignal, Response,
    self: {
      location: { origin: 'https://tally.example' },
      addEventListener: (name: string, handler: typeof handleFetch) => { if (name === 'fetch') handleFetch = handler },
    },
    caches: { match: async () => new Response('Connection screen') },
    fetch: async () => { if (!reachable) throw new Error('Offline'); return new Response('Current app', { status }) },
  })
  async function launch() {
    let result: Promise<Response> | undefined
    handleFetch({ request: { url: 'https://tally.example/', method: 'GET', mode: 'navigate' }, respondWith: response => { result = response } })
    assert.ok(result)
    return (await result).text()
  }
  assert.equal(await launch(), 'Current app')
  reachable = false
  assert.equal(await launch(), 'Connection screen')
  reachable = true
  status = 502
  assert.equal(await launch(), 'Connection screen')
  status = 200
  assert.equal(await launch(), 'Current app')
  for (const [path, method, mode] of [
    ['/api/v1/accounts', 'GET', 'cors'],
    ['/api/v1/accounts', 'GET', 'navigate'],
    ['/api/v1/accounts/account/redemptions', 'POST', 'cors'],
    ['/assets/app.js', 'GET', 'cors'],
  ]) {
    handleFetch({ request: { url: `https://tally.example${path}`, method, mode }, respondWith: () => assert.fail(`${path} must bypass the worker`) })
  }
})

test('reset response loss and reload recover the same UUID with reads only', async () => {
  const stored = new Map<string, string>()
  const storage = { getItem: (key: string) => stored.get(key) ?? null, setItem: (key: string, value: string) => { stored.set(key, value) }, removeItem: (key: string) => { stored.delete(key) } }
  const operations: Redemption[] = JSON.parse(readFileSync(new URL('../../Tests/TallyTests/Fixtures/redemptions.json', import.meta.url), 'utf8'))
  let operation = operations[0]
  const calls: { url: string; method: string }[] = []
  let offline = true
  const transport: typeof fetch = async (input, init) => {
    const url = String(input), method = init?.method ?? 'GET'
    calls.push({ url, method })
    if (method === 'POST') {
      const body = JSON.parse(String(init?.body))
      assert.equal(stored.get('tally.redemption.personal'), body.operationId)
      operation = { ...operation, operationId: body.operationId, requestedCreditId: body.creditId }
      throw new Error('Response lost after acceptance')
    }
    if (offline) throw new Error('Disconnected')
    assert.ok(url.endsWith(operation.operationId))
    return Response.json(operation)
  }
  const client = new RedemptionClient('personal', storage, transport)
  await client.submit('credit-a')
  assert.equal(client.blocked, true)
  await client.submit('credit-b')
  const restored = new RedemptionClient('personal', storage, transport)
  assert.equal(restored.operationId, operation.operationId)
  offline = false
  await restored.recover()
  assert.equal(restored.operation?.requestedCreditId, 'credit-a')
  operation = { ...operation, state: 'unknown', acknowledgementRequired: true }
  await restored.recover()
  assert.equal(restored.blocked, true)
  assert.equal(calls.filter(call => call.method === 'POST').length, 1)
  assert.equal(new RedemptionClient('other', storage, transport).blocked, false)
})

test('unknown acknowledgement failure retains the block and never consumes again', async () => {
  const operations: Redemption[] = JSON.parse(readFileSync(new URL('../../Tests/TallyTests/Fixtures/redemptions.json', import.meta.url), 'utf8'))
  let operation = operations[1]
  const storage = { getItem: () => operation.operationId, setItem: () => {}, removeItem: () => {} }
  let fail = true
  const calls: string[] = []
  const client = new RedemptionClient(operation.accountId, storage, async (url, init) => {
    calls.push(String(url))
    if (init?.method === 'POST') {
      assert.ok(String(url).endsWith('/acknowledge'))
      if (fail) return Response.json({ error: {} }, { status: 503 })
      operation = { ...operation, acknowledgedAt: '2030-09-07T00:01:00Z', acknowledgementRequired: false }
    }
    return Response.json(operation)
  })
  await client.recover()
  await client.acknowledge()
  assert.equal(client.blocked, true)
  assert.match(client.error!, /not confirmed/)
  assert.equal(client.operationId, operation.operationId)
  fail = false
  await client.acknowledge()
  assert.equal(client.blocked, false)
  assert.equal(client.operation?.state, 'unknown')
  assert.equal(calls.some(url => url.includes('/accounts/')), false)
})

test('reset controls decline unavailable identity storage and show confirmed stale wording', async () => {
  let sends = 0
  const client = new RedemptionClient('a', { getItem: () => null, setItem: () => { throw new Error('Full') }, removeItem: () => {} }, async () => { sends++; return Response.json({}) })
  await client.submit('credit-a')
  assert.equal(sends, 0)
  assert.match(client.error!, /No reset was sent/)
  const operations: Redemption[] = JSON.parse(readFileSync(new URL('../../Tests/TallyTests/Fixtures/redemptions.json', import.meta.url), 'utf8'))
  const account = decodeAccounts(readFileSync(new URL('../../Tests/TallyTests/Fixtures/accounts.json', import.meta.url), 'utf8')).accounts[0]
  assert.equal(redemptionLabel(operations[3], account), 'Reset confirmed. Current usage readings are stale or unavailable.')
  account.groups.quotas.stale = false; account.groups.quotas.error = null
  assert.equal(redemptionLabel(operations[3], account), 'Credit already redeemed; no additional reset claimed.')
  account.groups.quotas.stale = true
  assert.equal(redemptionLabel(operations[3], account), 'Reset confirmed. Current usage readings are stale or unavailable.')
  const credit: Credit = { id: 'a', type: null, status: 'available', available: true, title: null, description: null, grantedAt: null, expiry: { kind: 'unknown', at: null } }
  assert.equal(creditUsable(credit), true)
  assert.equal(creditUsable({ ...credit, expiry: { kind: 'none', at: null } }), true)
  assert.equal(creditUsable({ ...credit, expiry: { kind: 'at', at: '2000-01-01T00:00:00Z' } }), false)
  assert.equal(creditUsable({ ...credit, available: null }), false)
})

test('an older operation read cannot overwrite durable acknowledgement', async () => {
  const operations: Redemption[] = JSON.parse(readFileSync(new URL('../../Tests/TallyTests/Fixtures/redemptions.json', import.meta.url), 'utf8'))
  const unknown = operations[1]
  let reads = 0
  const delayed = Promise.withResolvers<Response>()
  const client = new RedemptionClient(unknown.accountId, { getItem: () => unknown.operationId, setItem: () => {}, removeItem: () => {} }, async (_url, init) => {
    if (init?.method === 'POST') return Response.json({ ...unknown, acknowledgementRequired: false, acknowledgedAt: '2030-09-07T00:01:00Z' })
    return ++reads === 1 ? Response.json(unknown) : delayed.promise
  })
  await client.recover()
  const reading = client.recover()
  await client.acknowledge()
  delayed.resolve(Response.json(unknown))
  await reading
  assert.equal(client.blocked, false)
  assert.equal(client.operation?.acknowledgementRequired, false)
})

test('a server rejection names the fault without creating a permanent browser-only block', async () => {
  const stored = new Map<string, string>()
  const client = new RedemptionClient('a', { getItem: key => stored.get(key) ?? null, setItem: (key, value) => { stored.set(key, value) }, removeItem: key => { stored.delete(key) } }, async () => Response.json({ error: { code: 'inventory_unavailable', message: 'Current Account identity is unavailable.', blockingOperationId: null } }, { status: 503 }))
  await client.submit('credit-a')
  assert.equal(client.blocked, false)
  assert.equal(client.operationId, null)
  assert.equal(stored.size, 0)
  assert.equal(client.error, 'Current Account identity is unavailable.')
})

test('orphan recovery clears identity only for authoritative faults with healthy owner storage', async () => {
  for (const [status, code, available, cleared] of [
    [404, 'operation_not_found', true, true],
    [400, 'invalid_request', true, true],
    [404, 'operation_not_found', false, false],
    [400, 'invalid_request', false, false],
    [404, 'not_found', true, false],
    [503, 'recovery_storage_unavailable', true, false],
  ] as const) {
    const stored = new Map([['tally.redemption.a', 'orphan']])
    const calls: string[] = []
    const client = new RedemptionClient('a', { getItem: key => stored.get(key) ?? null, setItem: (key, value) => { stored.set(key, value) }, removeItem: key => { stored.delete(key) } }, async (url, init) => {
      assert.equal(init?.method ?? 'GET', 'GET')
      calls.push(String(url))
      return String(url).endsWith('/status') ? Response.json({ apiMajor: 1, recoveryStorage: { available } }) : Response.json({ error: { code } }, { status })
    })
    await client.recover()
    assert.equal(client.blocked, !cleared)
    assert.equal(client.operationId, cleared ? null : 'orphan')
    assert.equal(stored.size, cleared ? 0 : 1)
    if (cleared) {
      assert.match(client.error!, /No reset was resent/)
      await client.recover()
      assert.equal(calls.length, 2)
    }
  }
})

test('orphan recovery retains identity when the storage health read fails', async () => {
  const client = new RedemptionClient('a', { getItem: () => 'orphan', setItem: () => {}, removeItem: () => { assert.fail('Must retain identity') } }, async url => {
    if (String(url).endsWith('/status')) throw new Error('Disconnected')
    return Response.json({ error: { code: 'operation_not_found' } }, { status: 404 })
  })
  await client.recover()
  assert.equal(client.blocked, true)
  assert.equal(client.operationId, 'orphan')
})

test('redemption wire states preserve original selection, uncertainty and explicit acknowledgement', () => {
  const operations: Redemption[] = JSON.parse(readFileSync(new URL('../../Tests/TallyTests/Fixtures/redemptions.json', import.meta.url), 'utf8'))
  assert.deepEqual(operations.map(operation => operation.state), ['pending', 'unknown', 'unknown', 'confirmed'])
  assert.equal(operations[0].selectedCreditId, null)
  assert.equal(operations[1].requestedCreditId, null)
  assert.equal(operations[1].selectedCreditId, 'credit-a')
  assert.equal(operations[1].acknowledgementRequired, true)
  assert.equal(operations[1].acknowledgedAt, null)
  assert.equal(operations[2].acknowledgementRequired, false)
  assert.equal(operations[2].acknowledgedAt, '2030-09-07T00:01:00.000Z')
  assert.equal(operations[2].providerResult, null)
  assert.equal(operations[3].providerResult?.code, 'already_redeemed')
  assert.equal(operations[3].providerResult?.windowsReset, null)
  for (const operation of operations) assert.equal(operation.resultUrl, `/api/v1/redemptions/${operation.operationId}`)
})

test('Grok PAYG uses the exact native/REST credit amounts without dollar conversion', () => {
  const extra: ExtraUsage = JSON.parse(readFileSync(new URL('../../Tests/TallyTests/Fixtures/grok-extra.json', import.meta.url), 'utf8'))
  assert.equal(extra.presentation, 'bounded')
  assert.equal(moneyLabel(extra.remaining), 'credits 2374.5')
  assert.equal(moneyLabel(extra.used), 'credits 125.5')
  assert.equal(percentage(extra.remainingPercent), '95%')
  assert.equal(extra.used?.source.unit, 'credits')
})

test('OpenAI shared normalized credits preserve provenance, zero, null, and expiry states', () => {
  const reading: { quotas: { windows: QuotaWindow[] }; balances: { items: Balance[] }; details: { credits: Credit[]; summary: ResetSummary } } = JSON.parse(readFileSync(new URL('../../Tests/TallyTests/Fixtures/openai-readings.json', import.meta.url), 'utf8'))
  const account = decodeAccounts(readFileSync(new URL('../../Tests/TallyTests/Fixtures/accounts.json', import.meta.url), 'utf8')).accounts[0]
  account.groups.quotas.data = reading.quotas
  assert.deepEqual(overviewWindows(account).map(window => window.label), ['Weekly'])
  assert.deepEqual(reading.quotas.windows.map(window => window.durationSeconds), [7200,604800,null])
  assert.equal(balanceLabel(reading.balances.items[0]), '12.5 credits (USD 0.5)')
  assert.equal(reading.balances.items[0].money, null)
  assert.equal(reading.balances.items[0].referenceValue?.provenance, 'reference_conversion')
  assert.equal(resetCountLabel(reading.details.summary), '2 reset credits')
  assert.equal(reading.details.summary.applicableAvailableCount, null)
  assert.equal(resetCountLabel({ ...reading.details.summary, availableCount: 0 }), '0 reset credits')
  assert.equal(resetCountLabel(null), 'Reset count unavailable')
  assert.equal(creditExpiryLabel(reading.details.credits[1], 'America/New_York'), 'Does not expire')
  assert.equal(creditExpiryLabel(reading.details.credits[2], 'America/New_York'), 'Expiry unknown')
  assert.match(creditExpiryLabel(reading.details.credits[0], 'America/New_York'), /2030/)
  assert.deepEqual(reading.details.credits.map(credit => credit.available), [true, true, null, false])
})

test('Swift wire fixture retains unknown, measured zero, stale failure, and two pin lines', () => {
  const response = decodeAccounts(readFileSync(new URL('../../Tests/TallyTests/Fixtures/accounts.json', import.meta.url), 'utf8'))
  const account = response.accounts[0]
  const windows = account.groups.quotas.data!.windows
  assert.equal(windows[0].remainingPercent, 87.5)
  assert.equal(windows[1].remainingPercent, null)
  assert.equal(windows[2].usedPercent, 0)
  assert.equal(windows[2].durationSeconds, null)
  assert.equal(account.pin.lines.length, 2)
  assert.equal(account.groups.quotas.error?.code, 'provider_unavailable')
  assert.equal(account.groups.extraUsage.data, null)
  assert.notEqual(account.groups.extraUsage.observedAt, null)
  assert.equal(percentage(windows[1].remainingPercent), '?')
  assert.equal(percentage(windows[2].remainingPercent), '100%')
  assert.equal(resetLabel(windows[1]), '')
  assert.equal(resetLabel(windows[0], Date.parse('2030-09-08T00:00:00Z')), 'Reset time passed; awaiting update')
})

test('incompatible API requires update', () => {
  assert.throws(() => decodeAccounts('{"status":{"apiMajor":2}}'), /incompatible/)
})

test('Anthropic cards consume exact owner money and overview scope flags', () => {
  const extra: ExtraUsage = JSON.parse(readFileSync(new URL('../../Tests/TallyTests/Fixtures/anthropic-extra.json', import.meta.url), 'utf8'))
  assert.equal(extra.presentation, 'bounded')
  assert.equal(moneyLabel(extra.remaining), 'USD 8.75')
  assert.equal(moneyLabel(extra.used), 'USD 1.25')
  assert.equal(extra.remainingPercent, 87.5)
  assert.equal(extra.used?.source.unit, 'amount_minor')
  const account = decodeAccounts(readFileSync(new URL('../../Tests/TallyTests/Fixtures/accounts.json', import.meta.url), 'utf8')).accounts[0]
  account.groups.quotas.data = JSON.parse(readFileSync(new URL('../../Tests/TallyTests/Fixtures/anthropic-quotas.json', import.meta.url), 'utf8'))
  assert.deepEqual(overviewWindows(account).map(window => window.id), ['session', 'weekly_all', 'weekly_scoped:fable', 'daily'])
  assert.equal(account.groups.quotas.data!.windows.length, 5)
  account.groups.quotas.data!.windows.reverse()
  assert.deepEqual(overviewWindows(account).map(window => window.id), ['session', 'weekly_all', 'weekly_scoped:fable', 'daily'])
  assert.match(overviewWindows(account)[2].scopeNote!, /up to half/)
  assert.equal(overviewWindows(account)[2].usedPercent, 40)
  assert.equal(overviewWindows(account)[2].modelId, null)
})

test('scheduling fixture distinguishes started, joined, cooldown, and credential block', () => {
  const response: RefreshResponse = JSON.parse(readFileSync(new URL('../../Tests/TallyTests/Fixtures/refresh.json', import.meta.url), 'utf8'))
  assert.deepEqual(response.accounts.map(item => item.schedule.state), ['started', 'joined', 'deferred', 'blocked'])
  assert.equal(scheduleLabel(response.accounts[0].schedule), 'Refresh requested')
  assert.equal(scheduleLabel(response.accounts[1].schedule), 'Joined existing refresh')
  assert.match(scheduleLabel(response.accounts[2].schedule), /^Deferred:/)
  assert.match(scheduleLabel(response.accounts[3].schedule), /Waiting for changed usable credentials/)
  assert.equal(response.accounts[2].schedule.nextAttemptAt, response.accounts[2].schedule.reason?.retryAt)
  assert.equal(response.activity.state, 'started')
})

test('cached browser readings age without advancing their successful observation', () => {
  const quota = decodeAccounts(readFileSync(new URL('../../Tests/TallyTests/Fixtures/accounts.json', import.meta.url), 'utf8')).accounts[0].groups.quotas
  quota.stale = false
  const observed = quota.observedAt!
  assert.equal(groupIsStale(quota, Date.parse(observed) + 299_999), false)
  assert.equal(groupIsStale(quota, Date.parse(observed) + 300_000), true)
  assert.equal(quota.observedAt, observed)
})

test('web pacing uses owner projections with native warning thresholds and countdowns', () => {
  const account = decodeAccounts(readFileSync(new URL('../../Tests/TallyTests/Fixtures/accounts.json', import.meta.url), 'utf8')).accounts[0]
  const now = Date.parse('2030-09-01T00:00:00Z')
  const window: QuotaWindow = { ...overviewWindows(account)[0], stale: false, usedPercent: 20, resetAt: new Date(now + 5 * 86400_000).toISOString(), pacing: { projectedUsedPercent: 120, sparePercent: -20, runOutAt: new Date(now + 3 * 86400_000 + 2 * 3600_000).toISOString(), runOutReason: null } }
  assert.equal(earlyLimitDate(window, false, now), Date.parse(window.pacing!.runOutAt!))
  assert.equal(countdown(earlyLimitDate(window, false, now)!, now), '3d 2h')
  assert.equal(earlyLimitDate({ ...window, usedPercent: 4 }, false, now), null)
  assert.notEqual(earlyLimitDate({ ...window, usedPercent: 5 }, false, now), null)
  assert.equal(earlyLimitDate(window, true, now), null)
  assert.equal(earlyLimitDate({ ...window, stale: true }, false, now), null)
  assert.equal(earlyLimitDate({ ...window, pacing: null }, false, now), null)
  assert.equal(earlyLimitDate({ ...window, resetAt: new Date(now).toISOString() }, false, now), null)
  assert.equal(earlyLimitDate({ ...window, pacing: { ...window.pacing!, runOutAt: null } }, false, now), null)
  assert.equal(resetLabel({ ...window, resetAt: null }, now), '')
  assert.equal(resetLabel({ ...window, resetAt: new Date(now + 20 * 60_000).toISOString() }, now), 'Resets in 0h 20m')
})

test('quota warnings explain collection failures, passed resets, and disconnection', () => {
  const account = decodeAccounts(readFileSync(new URL('../../Tests/TallyTests/Fixtures/accounts.json', import.meta.url), 'utf8')).accounts[0]
  const now = Date.parse('2030-09-08T00:00:00Z')
  account.groups.quotas.error = { code: 'rate_limited', message: 'Provider rate limited the request.', retryAt: null, blockingOperationId: null }
  const warning = quotaWarning(account, true, null, now)
  assert.match(warning, /Cannot reach Tally/)
  assert.match(warning, /Provider rate limited/)
  assert.match(warning, /older reading/)
  assert.match(warning, /reset time passed/)
})
