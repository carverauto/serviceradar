import {afterEach, describe, expect, it, vi} from "vitest"

import CameraVerticalTimeline, {
  computeLiveWindowUs,
  computeMarkerTopPct,
  computeVerticalFraction,
  formatRailTime,
} from "./CameraVerticalTimeline"

afterEach(() => {
  vi.useRealTimers()
})

describe("CameraVerticalTimeline hook", () => {
  it("computes clamped vertical fractions from top (0.0) to bottom (1.0)", () => {
    const rect = {top: 100, height: 400}
    expect(computeVerticalFraction(100, rect)).toBe(0)
    expect(computeVerticalFraction(300, rect)).toBe(0.5)
    expect(computeVerticalFraction(500, rect)).toBe(1)
    expect(computeVerticalFraction(50, rect)).toBe(0)
    expect(computeVerticalFraction(600, rect)).toBe(1)
    expect(computeVerticalFraction(200, {top: 0, height: 0})).toBeNull()
  })

  it("computes live sliding window bounds, marker percentages, and formatted rail times", () => {
    const fromUs = 1_760_000_000_000_000
    const toUs = fromUs + 3_600_000_000
    const win = computeLiveWindowUs(fromUs, toUs, 5000)
    expect(win.fromUs).toBe(fromUs + 5_000_000)
    expect(win.toUs).toBe(toUs + 5_000_000)
    expect(win.spanUs).toBe(3_600_000_000)

    // Caps drift cleanly at maxDriftUs
    const capped = computeLiveWindowUs(fromUs, toUs, 120_000, {maxDriftUs: 60_000_000})
    expect(capped.toUs).toBe(toUs + 60_000_000)

    // Newest at top (0.5% min), midpoint at 50%, oldest at bottom (99.5% max)
    expect(computeMarkerTopPct(toUs, fromUs, toUs)).toBe(0.5)
    expect(computeMarkerTopPct(fromUs + 1_800_000_000, fromUs, toUs)).toBe(50)
    expect(computeMarkerTopPct(fromUs, fromUs, toUs)).toBe(99.5)

    expect(formatRailTime(toUs, "Etc/UTC", {includeSeconds: true})).not.toBe("")
    expect(formatRailTime(toUs, "Invalid/Zone", {includeSeconds: false})).not.toBe("")
  })

  it("pushes seek_timeline_fraction on rail click and ignores clicks on event/thumbnail/semantic marker buttons", () => {
    const listeners = new Map()
    const hoverTime = {textContent: ""}
    const hoverLine = {
      style: {top: "0%"},
      hidden: true,
      querySelector: selector => (selector === "[data-role='vertical-timeline-hover-time']" ? hoverTime : null),
    }
    const el = {
      dataset: {
        fromUs: "1760000000000000",
        toUs: "1760003600000000",
        anchoredLatest: "false",
        timezone: "Etc/UTC",
      },
      getBoundingClientRect: () => ({top: 100, height: 400}),
      querySelector: selector => (selector === "[data-role='vertical-timeline-hover']" ? hoverLine : null),
      addEventListener: vi.fn((event, handler) => listeners.set(event, handler)),
    }

    const pushEvent = vi.fn()
    const hook = Object.create(CameraVerticalTimeline)
    hook.el = el
    hook.pushEvent = pushEvent

    hook.mounted()

    // Click at 25% down the rail (y = 200)
    listeners.get("click")({
      clientY: 200,
      target: {closest: () => null},
    })

    expect(pushEvent).toHaveBeenCalledWith("seek_timeline_fraction", {fraction: 0.25})

    // Click on an event pill or inline mini thumbnail should not double-trigger seek_timeline_fraction
    pushEvent.mockClear()
    listeners.get("click")({
      clientY: 250,
      target: {closest: () => ({dataset: {role: "event-clip-marker"}})},
    })
    listeners.get("click")({
      clientY: 250,
      target: {closest: () => ({dataset: {role: "event-thumb-marker"}})},
    })
    expect(pushEvent).not.toHaveBeenCalled()

    // Hover updates crosshair position + timestamp label and hides on leave
    listeners.get("mousemove")({clientY: 300})
    expect(hoverLine.hidden).toBe(false)
    expect(hoverLine.style.top).toBe("50.00%")
    expect(hoverTime.textContent).not.toBe("")

    listeners.get("mouseleave")()
    expect(hoverLine.hidden).toBe(true)

    hook.destroyed()
  })

  it("smoothly ticks time ruler labels and shifts event markers/thumbnails every 1s when anchored to latest/live", () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-11-23T20:00:00Z"))

    const toUs = Date.UTC(2026, 10, 23, 20, 0, 0) * 1000
    const fromUs = toUs - 900_000_000 // 15m span
    const eventTsUs = toUs - 180_000_000 // 3m ago -> initial topPct = 20%

    const topTick = {dataset: {tickFraction: "0"}, textContent: "initial-top"}
    const midTick = {dataset: {tickFraction: "0.5"}, textContent: "initial-mid"}
    const eventMarker = {dataset: {eventTsUs: String(eventTsUs)}, style: {top: "20%"}}
    const eventThumb = {dataset: {eventTsUs: String(eventTsUs)}, style: {top: "20%"}}

    const parentElement = {
      querySelectorAll: selector =>
        selector === "[data-role='vertical-tick-label']" ? [topTick, midTick] : [],
    }

    const el = {
      parentElement,
      dataset: {
        fromUs: String(fromUs),
        toUs: String(toUs),
        anchoredLatest: "true",
        timezone: "Etc/UTC",
      },
      addEventListener: vi.fn(),
      querySelector: () => null,
      querySelectorAll: selector => {
        if (selector === "[data-role='event-clip-marker'][data-event-ts-us]") return [eventMarker]
        if (selector === "[data-role='event-thumb-marker'][data-event-ts-us]") return [eventThumb]
        return []
      },
    }

    const hook = Object.create(CameraVerticalTimeline)
    hook.el = el
    hook.mounted()

    // Advance 9 seconds -> event should move downward by 9s / 900s = 1% (from 20% to 21%)
    vi.advanceTimersByTime(9000)

    expect(topTick.textContent).not.toBe("initial-top")
    expect(midTick.textContent).not.toBe("initial-mid")
    expect(eventMarker.style.top).toBe("21%")
    expect(eventThumb.style.top).toBe("21%")

    // Switching to historical (anchoredLatest = false) stops the ticker
    el.dataset.anchoredLatest = "false"
    hook.updated()
    const frozenTop = eventMarker.style.top
    vi.advanceTimersByTime(5000)
    expect(eventMarker.style.top).toBe(frozenTop)

    hook.destroyed()
  })
})
