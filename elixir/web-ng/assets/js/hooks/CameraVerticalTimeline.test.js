import {describe, expect, it, vi} from "vitest"

import CameraVerticalTimeline, {computeVerticalFraction} from "./CameraVerticalTimeline"

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

  it("pushes seek_timeline_fraction on rail click and ignores clicks on marker buttons", () => {
    const listeners = new Map()
    const hoverLine = {style: {top: "0%"}, hidden: true}
    const el = {
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

    // Click on a marker button should not double-trigger seek_timeline_fraction
    pushEvent.mockClear()
    listeners.get("click")({
      clientY: 250,
      target: {closest: () => ({dataset: {role: "event-clip-marker"}})},
    })
    expect(pushEvent).not.toHaveBeenCalled()

    // Hover updates crosshair position and hides on leave
    listeners.get("mousemove")({clientY: 300})
    expect(hoverLine.hidden).toBe(false)
    expect(hoverLine.style.top).toBe("50.00%")

    listeners.get("mouseleave")()
    expect(hoverLine.hidden).toBe(true)

    hook.destroyed()
  })
})
