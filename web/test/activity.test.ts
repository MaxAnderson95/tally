import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { costLabel, decodeActivity, estimateLabel, estimateQualification, tokenLabel, type ActivityData } from '../src/activity.ts'

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

test('Swift pricing fixture exposes partial subset bounds, ranged models, and one revision', () => {
  const data: ActivityData = JSON.parse(readFileSync(new URL('../../Tests/TallyTests/Fixtures/activity-pricing.json', import.meta.url), 'utf8'))
  assert.equal(data.pricing.revision, '2026-09-07-r1')
  assert.equal(data.pricing.digest, '1753c13f0c8e53de55320e6318319d7601010468610772197002f0dae2ad70c5')
  assert.equal(data.totals.estimate.status, 'partial')
  assert.equal(data.totals.estimate.lower, '0.06')
  assert.equal(data.totals.estimate.upper, '0.0675')
  assert.match(estimateLabel(data.totals.estimate), /partial subtotal: \$0.06 to \$0.0675 USD/)
  assert.match(estimateQualification(data.totals.estimate), /does not bound all activity/)
  const anthropic = data.providers[0].models[0].totals.estimate
  assert.equal(anthropic.status, 'range')
  assert.equal(anthropic.lower, '0.05')
  assert.equal(anthropic.upper, '0.0575')
  assert.match(estimateQualification(anthropic), /5m\/1h/)
  const xai = data.providers[1].totals.estimate
  assert.equal(xai.coverage.partiallyPricedRows, 1)
  assert.equal(xai.coverage.unpricedComponents.cacheWrite, 1000)
  assert.equal(xai.exclusions[0].tokens?.total, 1000)
  assert.equal(data.trend.days.at(-1)?.totals.estimate.upper, '0.0675')
  assert.equal(estimateLabel(data.trend.days[0].totals.estimate), 'API-equivalent estimate: No recorded activity')
})
