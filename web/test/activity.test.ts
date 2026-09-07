import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { costLabel, decodeActivity, tokenLabel } from '../src/activity.ts'

test('Swift activity fixture retains nullable pricing, five components, and 30 calendar buckets', () => {
  const response = decodeActivity(readFileSync(new URL('../../Tests/TallyTests/Fixtures/activity.json', import.meta.url), 'utf8'))
  const data = response.activity.data!
  assert.equal(data.range, 'last30days')
  assert.equal(data.source.attribution, 'provider_local_database')
  assert.equal(data.source.partialHistory, true)
  assert.equal(data.trend.days.length, 30)
  assert.equal(data.trend.days.filter(day => day.selected).length, 30)
  assert.equal(data.totals.tokens?.input, 1)
  assert.equal(data.totals.tokens?.total, 1)
  assert.equal(data.totals.estimate.status, 'unpriced')
  assert.equal(data.totals.estimate.lower, null)
  assert.equal(data.totals.estimate.upper, null)
  assert.equal(data.totals.recordedCost.amount, '0')
  assert.equal(costLabel(data.totals), 'Recorded $0; pricing provenance unknown')
  assert.equal(data.totals.estimate.coverage.unpricedRows, 2)
  assert.equal(data.totals.missingUsageRows, 1)
  assert.equal(data.providers[0].totals.tokens, null)
  assert.equal(data.providers[0].totals.estimate.exclusions[0].tokens, null)
  assert.equal(data.providers[2].totals.tokens?.total, 0)
  assert.equal(data.providers[2].totals.estimate.status, 'unpriced')
  const empty = data.trend.days[0].totals
  assert.equal(tokenLabel(empty), 'No recorded activity')
  assert.equal(costLabel(empty), 'Recorded cost: no recorded activity')
  assert.equal(empty.estimate.status, 'empty')
  assert.equal(empty.estimate.lower, '0')
  assert.equal(tokenLabel({ ...empty, rows: 1, tokens: null, missingUsageRows: 1 }), 'Usage missing')
  assert.equal(costLabel({ ...empty, rows: 1, recordedCost: { ...empty.recordedCost, amount: null } }), 'Recorded cost unavailable')
  for (const day of data.trend.days) {
    assert.ok(day.startAt <= day.endAt)
    const coverage = day.totals.estimate.coverage
    assert.equal(coverage.fullyPricedRows + coverage.boundedRows + coverage.partiallyPricedRows + coverage.unpricedRows + coverage.missingUsageRows, day.totals.rows)
  }
})
