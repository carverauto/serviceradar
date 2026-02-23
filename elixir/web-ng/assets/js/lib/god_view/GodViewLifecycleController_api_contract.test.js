import {describe, expect, it, vi} from "vitest"

vi.mock("./lifecycle_methods", () => ({
  godViewLifecycleMethods: {
    mounted() {},
    destroyed() {},
    ensureDeck() {},
    initLifecycleState() {},
  },
}))

import GodViewLifecycleController from "./GodViewLifecycleController"
import {godViewLifecycleMethods} from "./lifecycle_methods"

describe("GodViewLifecycleController API contract", () => {
  it("getContextApi exposes all lifecycle methods", () => {
    const controller = new GodViewLifecycleController({state: {}, deps: {}})

    expect(Object.keys(controller.getContextApi())).toEqual(Object.keys(godViewLifecycleMethods))
  })

  it("mount/destroy delegate to composed lifecycle handlers", () => {
    const controller = new GodViewLifecycleController({state: {}, deps: {}})
    const contextApi = controller.getContextApi()
    const mountedSpy = vi.spyOn(contextApi, "mounted")
    const destroyedSpy = vi.spyOn(contextApi, "destroyed")

    controller.mount()
    controller.destroy()

    expect(mountedSpy).toHaveBeenCalledTimes(1)
    expect(destroyedSpy).toHaveBeenCalledTimes(1)
  })
})
