import assert from "node:assert/strict"
import {test} from "node:test"
import {sparklinePaths} from "../lib/sparkline.js"

test("breaks the line at gaps", () => {
  const {line, empty} = sparklinePaths([1, null, 2, 3], {smooth: false})
  assert.equal(empty, false)
  assert.equal((line.match(/M/g) || []).length, 2)
  assert.doesNotMatch(line, /style=/)
})

test("an empty series has no line", () => {
  const {line, empty} = sparklinePaths([null, null], {smooth: true})
  assert.equal(line, "")
  assert.equal(empty, true)
})
