import {describe, expect, it, vi} from "vitest"

import {runRecoverableManagedCameraUpdate} from "./lifecycle_managed_camera_recovery"

describe("lifecycle_managed_camera_recovery", () => {
  it("replaces stale summary ownership when a later accepted snapshot is already visible", () => {
    const state = {
      summary: {textContent: "snapshot A"},
      pushEvent: vi.fn(),
      managedTopologyCameraErrorActive: false,
    }
    const context = {state}

    runRecoverableManagedCameraUpdate(context, () => {
      throw new RangeError("first failure")
    })
    state.summary.textContent = "snapshot B"
    runRecoverableManagedCameraUpdate(context, () => {
      throw new RangeError("second failure")
    })
    runRecoverableManagedCameraUpdate(context, () => 42)

    expect(state.summary.textContent).toBe("snapshot B")
    expect(state.managedTopologyCameraErrorActive).toBe(false)
    expect(state.managedTopologyCameraErrorPreviousSummary).toBeNull()
    expect(state.pushEvent).toHaveBeenCalledTimes(2)
    expect(state.pushEvent).toHaveBeenLastCalledWith("god_view_stream_error", {
      reason: "render_error",
      message: "RangeError: second failure",
    })
  })

  it("does not let a repeated failed update replace the accepted summary with transient text", () => {
    const state = {
      summary: {textContent: "accepted topology"},
      pushEvent: vi.fn(),
      managedTopologyCameraErrorActive: false,
    }
    const context = {state}

    runRecoverableManagedCameraUpdate(context, () => {
      throw new RangeError("first failure")
    })
    runRecoverableManagedCameraUpdate(context, () => {
      state.summary.textContent = "transient failed selection"
      throw new RangeError("second failure")
    })
    runRecoverableManagedCameraUpdate(context, () => 42)

    expect(state.summary.textContent).toBe("accepted topology")
    expect(state.managedTopologyCameraErrorActive).toBe(false)
  })
})
