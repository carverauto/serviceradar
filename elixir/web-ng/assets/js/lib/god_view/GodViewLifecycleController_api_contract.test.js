import {describe, expect, it, vi} from "vitest"

import GodViewLifecycleController from "./GodViewLifecycleController"
import {godViewLifecycleMethods} from "./lifecycle_methods"

describe("GodViewLifecycleController API contract", () => {
  it("getContextApi exposes all lifecycle methods", () => {
    const controller = new GodViewLifecycleController({state: {}, deps: {}})

    expect(Object.keys(controller.getContextApi()).sort()).toEqual(
      Object.keys(godViewLifecycleMethods).sort(),
    )
  })

  it("mount/destroy delegate to composed lifecycle handlers", () => {
    const controller = new GodViewLifecycleController({state: {}, deps: {}})
    const mounted = vi.fn()
    const destroyed = vi.fn()

    controller.contextApi.mounted = mounted
    controller.contextApi.destroyed = destroyed

    controller.mount()
    controller.destroy()

    expect(mounted).toHaveBeenCalledTimes(1)
    expect(destroyed).toHaveBeenCalledTimes(1)
  })
})
