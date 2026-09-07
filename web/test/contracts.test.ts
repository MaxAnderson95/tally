import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { balanceLabel, creditExpiryLabel, resetCountLabel, decodeAccounts, groupIsStale, moneyLabel, overviewWindows, percentage, resetLabel, scheduleLabel, type QuotaWindow, type Balance, type Credit, type ResetSummary, type ExtraUsage, type RefreshResponse } from '../src/api.ts'

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
