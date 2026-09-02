import {describe, expect, it} from "vitest"

import {
  nearestRangeBucketIndex,
  overlayForBucketIndexes,
  parseRangeBuckets,
  rangeForBucketIndexes,
} from "./chart_range_selection"

describe("chart range selection helpers", () => {
  const buckets = [
    {x: 36, start: "2026-08-27T10:00:00Z", end: "2026-08-27T10:59:59.999999Z"},
    {x: 326, start: "2026-08-27T12:00:00Z", end: "2026-08-27T12:59:59.999999Z"},
    {x: 616, start: "2026-08-27T13:00:00Z", end: "2026-08-27T13:59:59.999999Z"},
  ]

  it("parses ordered rendered buckets without changing their timestamps", () => {
    expect(parseRangeBuckets(JSON.stringify(buckets))).toEqual(buckets)
  })

  it("snaps viewBox coordinates to the nearest rendered bucket", () => {
    expect(nearestRangeBucketIndex(buckets, 300)).toBe(1)
    expect(nearestRangeBucketIndex(buckets, -100)).toBe(0)
    expect(nearestRangeBucketIndex(buckets, 900)).toBe(2)
    expect(nearestRangeBucketIndex(buckets, 181)).toBe(0)
  })

  it("normalizes reverse bucket indexes into an inclusive range", () => {
    expect(rangeForBucketIndexes(buckets, 2, 0)).toEqual({
      start: "2026-08-27T10:00:00Z",
      end: "2026-08-27T13:59:59.999999Z",
      startIndex: 0,
      endIndex: 2,
    })
  })

  it("uses rendered-anchor geometry for a single-bucket overlay", () => {
    expect(overlayForBucketIndexes(buckets, 0, 0, 36, 616)).toEqual({x: 36, width: 145})
  })

  it("covers a true one-bucket chart across the plot", () => {
    const oneBucket = [buckets[0]]

    expect(overlayForBucketIndexes(oneBucket, 0, 0, 36, 616)).toEqual({x: 36, width: 580})
  })

  it("uses asymmetric neighbor midpoints and clamps an edge outside the plot", () => {
    const unevenBuckets = [
      {x: 50, start: "2026-08-27T10:00:00Z", end: "2026-08-27T10:59:59.999999Z"},
      {x: 180, start: "2026-08-27T11:00:00Z", end: "2026-08-27T11:59:59.999999Z"},
      {x: 700, start: "2026-08-27T12:00:00Z", end: "2026-08-27T12:59:59.999999Z"},
    ]

    expect(overlayForBucketIndexes(unevenBuckets, 1, 1, 100, 400)).toEqual({x: 115, width: 285})
  })

  it("uses neighbor midpoints and clamps the selected overlay to the plot", () => {
    expect(overlayForBucketIndexes(buckets, 2, 1, 36, 616)).toEqual({x: 181, width: 435})
    expect(overlayForBucketIndexes(buckets, 0, 2, 36, 616)).toEqual({x: 36, width: 580})
  })

  it.each([
    ["malformed JSON", "{"],
    ["non-array JSON", JSON.stringify({x: 1})],
    ["empty JSON array", "[]"],
    ["duplicate x positions", JSON.stringify([{...buckets[0]}, {...buckets[1], x: 36}])],
    ["decreasing x positions", JSON.stringify([{...buckets[0], x: 326}, {...buckets[1], x: 36}])],
    ["non-finite x positions", JSON.stringify([{...buckets[0], x: null}])],
    ["impossible calendar date", JSON.stringify([{...buckets[0], start: "2026-02-31T10:00:00Z"}])],
    ["non-RFC3339 date", JSON.stringify([{...buckets[0], start: "2026-08-27 10:00:00Z"}])],
    ["invalid timezone", JSON.stringify([{...buckets[0], start: "2026-08-27T10:00:00+24:00"}])],
    ["start equal to end", JSON.stringify([{...buckets[0], end: buckets[0].start}])],
    ["start after end", JSON.stringify([{...buckets[0], start: buckets[0].end, end: buckets[0].start}])],
  ])("rejects %s metadata", (_label, serialized) => {
    expect(parseRangeBuckets(serialized)).toBeNull()
  })

  it.each([undefined, null, 42, {}, []])("rejects non-serialized input %p", (serialized) => {
    expect(parseRangeBuckets(serialized)).toBeNull()
  })
})
