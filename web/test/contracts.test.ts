import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { balanceLabel, creditExpiryLabel, resetCountLabel, decodeAccounts, groupIsStale, moneyLabel, overviewWindows, percentage, resetLabel, scheduleLabel, type QuotaWindow, type Balance, type Credit, type ResetSummary, type ExtraUsage, type RefreshResponse } from '../src/api.ts'
import type { Redemption } from '../src/api.ts'
import { creditUsable, RedemptionClient, redemptionLabel } from '../src/redemptions.ts'

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
  assert.equal(redemptionLabel(operations[3], account), 'Reset confirmed; usage update unavailable')
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
  assert.equal(resetLabel(windows[1]), 'Reset time unavailable')
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
