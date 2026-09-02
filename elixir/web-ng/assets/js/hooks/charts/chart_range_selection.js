const RFC3339_TIMESTAMP = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})$/

function daysInMonth(year, month) {
  if (month === 2) {
    return year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0) ? 29 : 28
  }

  return [4, 6, 9, 11].includes(month) ? 30 : 31
}

function timestampValue(value) {
  if (typeof value !== "string") return null

  const match = value.match(RFC3339_TIMESTAMP)
  if (!match) return null

  const [, yearText, monthText, dayText, hourText, minuteText, secondText, fractionText = "", zone] = match
  const year = Number(yearText)
  const month = Number(monthText)
  const day = Number(dayText)
  const hour = Number(hourText)
  const minute = Number(minuteText)
  const second = Number(secondText)

  if (
    month < 1 ||
    month > 12 ||
    day < 1 ||
    day > daysInMonth(year, month) ||
    hour > 23 ||
    minute > 59 ||
    second > 59
  ) {
    return null
  }

  let offsetMinutes = 0
  if (zone !== "Z") {
    const offsetMatch = zone.match(/^([+-])(\d{2}):(\d{2})$/)
    if (!offsetMatch) return null

    const offsetHours = Number(offsetMatch[2])
    const offsetSeconds = Number(offsetMatch[3])
    if (offsetHours > 23 || offsetSeconds > 59) return null

    offsetMinutes = offsetHours * 60 + offsetSeconds
    if (offsetMatch[1] === "-") offsetMinutes = -offsetMinutes
  }

  const date = new Date(0)
  date.setUTCFullYear(year, month - 1, day)
  date.setUTCHours(hour, minute, second, 0)
  if (!Number.isFinite(date.getTime())) return null

  const fractionNanos = BigInt(fractionText.padEnd(9, "0") || "0")
  return BigInt(date.getTime() - offsetMinutes * 60 * 1000) * 1_000_000n + fractionNanos
}

export function validRangeBuckets(buckets) {
  if (!Array.isArray(buckets) || buckets.length === 0) return false

  return buckets.every((bucket, index) => {
    if (!Number.isFinite(bucket?.x)) return false
    return index === 0 || bucket.x > buckets[index - 1].x
  })
}

export function parseRangeBuckets(serialized) {
  if (typeof serialized !== "string") return null

  let parsed
  try {
    parsed = JSON.parse(serialized)
  } catch {
    return null
  }

  if (!Array.isArray(parsed) || parsed.length === 0) return null

  const buckets = parsed.map((bucket) => {
    if (!bucket || typeof bucket !== "object" || Array.isArray(bucket)) return null
    if (!Number.isFinite(bucket.x)) return null

    const start = timestampValue(bucket.start)
    const end = timestampValue(bucket.end)
    if (start === null || end === null || start >= end) return null

    return {x: bucket.x, start: bucket.start, end: bucket.end}
  })

  if (buckets.some((bucket) => bucket === null) || !validRangeBuckets(buckets)) return null
  return buckets
}

export function nearestRangeBucketIndex(buckets, viewX) {
  if (!validRangeBuckets(buckets) || !Number.isFinite(viewX)) return null

  let nearestIndex = 0
  let nearestDistance = Math.abs(buckets[0].x - viewX)

  for (let index = 1; index < buckets.length; index += 1) {
    const distance = Math.abs(buckets[index].x - viewX)
    if (distance < nearestDistance) {
      nearestIndex = index
      nearestDistance = distance
    }
  }

  return nearestIndex
}

export function rangeForBucketIndexes(buckets, anchorIndex, activeIndex) {
  if (!validRangeBuckets(buckets)) return null
  if (!Number.isInteger(anchorIndex) || !Number.isInteger(activeIndex)) return null

  const startIndex = Math.max(0, Math.min(anchorIndex, activeIndex))
  const endIndex = Math.min(buckets.length - 1, Math.max(anchorIndex, activeIndex))
  const first = buckets[startIndex]
  const last = buckets[endIndex]

  if (!first || !last) return null
  return {start: first.start, end: last.end, startIndex, endIndex}
}

export function overlayForBucketIndexes(buckets, anchorIndex, activeIndex, plotLeft, plotRight) {
  const selectedRange = rangeForBucketIndexes(buckets, anchorIndex, activeIndex)
  if (!selectedRange || !Number.isFinite(plotLeft) || !Number.isFinite(plotRight)) return null

  const leftPlotEdge = Math.min(plotLeft, plotRight)
  const rightPlotEdge = Math.max(plotLeft, plotRight)
  const {startIndex, endIndex} = selectedRange
  const firstX = buckets[startIndex].x
  const lastX = buckets[endIndex].x

  const leftEdge = startIndex === 0 ? leftPlotEdge : (buckets[startIndex - 1].x + firstX) / 2
  const rightEdge = endIndex === buckets.length - 1 ? rightPlotEdge : (lastX + buckets[endIndex + 1].x) / 2
  const x = Math.max(leftPlotEdge, Math.min(rightPlotEdge, leftEdge))
  const right = Math.max(x, Math.min(rightPlotEdge, rightEdge))

  return {x, width: Math.max(0, right - x)}
}
