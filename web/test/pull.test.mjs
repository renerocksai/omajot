import { test } from 'node:test'
import assert from 'node:assert/strict'
import { pullPhase, PULL_THRESHOLD } from '../src/pull.js'

test('a pull only counts from the top of the list, and releases past the threshold', () => {
  assert.equal(pullPhase(false, 200), 'idle', 'not at the top: normal scrolling')
  assert.equal(pullPhase(true, 5), 'idle', 'a tiny move is not a pull')
  assert.equal(pullPhase(true, -40), 'idle', 'pushing up is scrolling')
  assert.equal(pullPhase(true, 30), 'pull')
  assert.equal(pullPhase(true, PULL_THRESHOLD - 1), 'pull')
  assert.equal(pullPhase(true, PULL_THRESHOLD), 'release')
})
