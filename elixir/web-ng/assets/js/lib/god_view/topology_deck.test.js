import {describe, expect, it, vi} from "vitest"
import {TopologyDeck} from "./topology_deck"

const lifecycle = vi.hoisted(() => [])
vi.mock("@deck.gl/core", () => ({Deck: class {
  constructor(props) {this.props = props; this.creation = props.deviceProps.adapters[0].create(props.deviceProps)}
  finalize() {lifecycle.push("layers finalized")}
}}))

function deferred() {
  let resolve
  const promise = new Promise(done => {resolve = done})
  return {promise, resolve}
}

describe("topology GPU ownership", () => {
  it("drains submitted work and frees only its own device across remounts", async () => {
    lifecycle.length = 0
    const pending = deferred()
    const first = {submit: () => lifecycle.push("submitted"), destroy: vi.fn(), handle: {queue: {onSubmittedWorkDone: () => pending.promise}}}
    const second = {submit() {}, destroy: vi.fn()}
    const adapter = {type: "webgpu", create: vi.fn().mockResolvedValueOnce(first).mockResolvedValueOnce(second)}
    const props = {canvas: {}, deviceProps: {type: "webgpu", adapters: [adapter]}}
    const original = new TopologyDeck(props)
    const remount = new TopologyDeck({...props, canvas: {}})
    await Promise.all([original.creation, remount.creation])
    original.finalize()
    expect(lifecycle).toEqual(["submitted", "layers finalized"])
    expect(first.destroy).not.toHaveBeenCalled()
    pending.resolve()
    await Promise.resolve()
    expect(first.destroy).toHaveBeenCalledOnce()
    expect(second.destroy).not.toHaveBeenCalled()
    original.finalize()
    expect(first.destroy).toHaveBeenCalledOnce()
    remount.finalize()
    expect(second.destroy).toHaveBeenCalledOnce()
    expect(adapter.create.mock.calls.at(-1)[0]._reuseDevices).toBe(false)
  })

  it("releases a device that finishes creating after its map has unmounted", async () => {
    const pending = deferred()
    const device = {destroy: vi.fn()}
    const adapter = {type: "webgpu", create: () => pending.promise}
    const deck = new TopologyDeck({canvas: {}, deviceProps: {type: "webgpu", adapters: [adapter]}})
    deck.finalize()
    pending.resolve(device)
    await expect(deck.creation).rejects.toThrow("GPU device closed during creation")
    expect(device.destroy).toHaveBeenCalledOnce()
  })
})
