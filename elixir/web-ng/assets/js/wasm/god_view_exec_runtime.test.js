import {describe, expect, it} from "vitest"
import {wasmCandidates} from "./god_view_exec_runtime"

describe("god_view_exec wasm candidates", () => {
  it("uses the stable Phoenix asset path without import.meta.url", () => {
    expect(wasmCandidates()).toEqual(["/assets/js/god_view_exec.wasm", "/god_view_exec.wasm"])
  })
})
