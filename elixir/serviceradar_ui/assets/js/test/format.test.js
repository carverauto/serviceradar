import assert from "node:assert/strict"
import {test} from "node:test"
import {formatInstant, formatValue} from "../lib/format.js"

test("formats chart units", () => {
  assert.equal(formatValue(null, "ms"), "-")
  assert.equal(formatValue(42.25, "percent"), "42.3%")
  assert.equal(formatValue(1536, "bytes"), "1.54 KB")
  assert.equal(formatValue(1500, "ms"), "1.5 s")
  assert.equal(formatValue(12, "count_per_sec"), "12/s")
})

test("formats instants in the requested zone", () => {
  const iso = "2026-11-27T15:04:00Z"
  assert.equal(formatInstant(iso, {timeZone: "Etc/UTC", format: "time", locale: "en-GB"}), "15:04")
  assert.match(
    formatInstant(iso, {timeZone: "Etc/UTC", format: "datetime", locale: "en-GB"}),
    /27 Nov.*15:04|Nov 27.*15:04/,
  )
  assert.equal(
    formatInstant(iso, {timeZone: "Etc/UTC", format: "auto", locale: "en-GB", spanMs: 3 * 86_400_000}),
    formatInstant(iso, {timeZone: "Etc/UTC", format: "date", locale: "en-GB"}),
  )
})
