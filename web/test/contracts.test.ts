import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { decodeAccounts, percentage, resetLabel } from '../src/api.ts'

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
