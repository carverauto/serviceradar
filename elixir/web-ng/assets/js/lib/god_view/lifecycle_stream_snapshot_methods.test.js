import {describe, expect, it, vi} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewLifecycleStreamSnapshotMethods} from "./lifecycle_stream_snapshot_methods"

function buildFrame(payloadBytes) {
  const payload = Uint8Array.from(payloadBytes)
  const out = new Uint8Array(53 + payload.length)
  out[0] = "G".charCodeAt(0)
  out[1] = "V".charCodeAt(0)
  out[2] = "B".charCodeAt(0)
  out[3] = "1".charCodeAt(0)

  const view = new DataView(out.buffer)
  view.setUint8(4, 2)
  view.setBigUint64(5, 42n, false)
  view.setBigInt64(13, 1_700_000_000_000n, false)
  view.setUint32(21, 11, false)
  view.setUint32(25, 12, false)
  view.setUint32(29, 13, false)
  view.setUint32(33, 14, false)
  view.setUint32(37, 3, false)
  view.setUint32(41, 4, false)
  view.setUint32(45, 5, false)
  view.setUint32(49, 6, false)
  out.set(payload, 53)

  return out.buffer
}

describe("lifecycle_stream_snapshot_methods", () => {
  it("parseBinarySnapshotFrame decodes header and payload", () => {
    const frame = buildFrame([7, 8, 9])
    const parsed = godViewLifecycleStreamSnapshotMethods.parseBinarySnapshotFrame(frame)

    expect(parsed.schemaVersion).toEqual(2)
    expect(parsed.revision).toEqual(42)
    expect(parsed.bitmapMetadata.root_cause.bytes).toEqual(11)
    expect(parsed.bitmapMetadata.unknown.count).toEqual(6)
    expect(Array.from(parsed.payload)).toEqual([7, 8, 9])
  })

  it("parseSnapshotMessage supports binary tuple payload", () => {
    const state = {}
    const methods = createStateBackedContext(state, {})
    Object.assign(methods, bindApi(methods, godViewLifecycleStreamSnapshotMethods))
    const frame = buildFrame([1, 2])
    const encoded = Buffer.from(new Uint8Array(frame)).toString("base64")

    const parsed = methods.parseSnapshotMessage(["binary", encoded])
    expect(Array.from(parsed.payload)).toEqual([1, 2])
  })

  it("parseBinarySnapshotFrame rejects invalid magic", () => {
    const frame = new Uint8Array(buildFrame([1]))
    frame[0] = "X".charCodeAt(0)

    expect(() => godViewLifecycleStreamSnapshotMethods.parseBinarySnapshotFrame(frame.buffer)).toThrow(
      /unexpected binary snapshot magic/,
    )
  })

  it("handleSnapshot skips decode and render when revision is unchanged", async () => {
    const state = {
      lastRevision: 42,
      lastSnapshotAt: 0,
      layoutRequestToken: 0,
      pushEvent: () => {},
      summary: {textContent: ""},
    }
    const deps = {
      decodeArrowGraph: () => {
        throw new Error("decode should not run")
      },
      graphTopologyStamp: () => "stamp",
      prepareGraphLayout: () => {
        throw new Error("layout should not run")
      },
      ensureBitmapMetadata: () => ({}),
      sameTopology: () => false,
      renderGraph: () => {
        throw new Error("render should not run")
      },
      animateTransition: () => {
        throw new Error("animate should not run")
      },
      normalizePipelineStats: () => ({}),
    }
    const methods = createStateBackedContext(state, deps)
    Object.assign(methods, bindApi(methods, godViewLifecycleStreamSnapshotMethods))

    await methods.handleSnapshot(buildFrame([1, 2, 3]))

    expect(state.lastSnapshotAt).toBeGreaterThan(0)
  })

  it("handleSnapshot awaits async layout preparation before rendering", async () => {
    const state = {
      lastRevision: null,
      lastSnapshotAt: 0,
      layoutRequestToken: 0,
      lastGraph: null,
      lastVisibleNodeCount: 0,
      selectedNodeIndex: null,
      rendererMode: "deck",
      zoomTier: "local",
      zoomMode: "local",
      lastPipelineStats: null,
      pushEvent: vi.fn(),
      summary: {textContent: ""},
    }

    const graph = {nodes: [{id: "a", x: 10, y: 20}], edges: [], _layoutMode: "elk-client"}
    const deps = {
      decodeArrowGraph: vi.fn(() => ({nodes: [{id: "a"}], edges: []})),
      graphTopologyStamp: vi.fn(() => "stamp"),
      prepareGraphLayout: vi.fn(async () => graph),
      ensureBitmapMetadata: vi.fn(() => ({})),
      sameTopology: vi.fn(() => false),
      renderGraph: vi.fn(),
      animateTransition: vi.fn(),
      normalizePipelineStats: vi.fn(() => ({})),
    }

    const methods = createStateBackedContext(state, deps)
    Object.assign(methods, bindApi(methods, godViewLifecycleStreamSnapshotMethods))

    await methods.handleSnapshot(buildFrame([1, 2, 3]))

    expect(deps.prepareGraphLayout).toHaveBeenCalledTimes(1)
    expect(deps.animateTransition).toHaveBeenCalledWith(null, graph)
    expect(state.lastGraph).toBe(graph)
    expect(state.summary.textContent).toContain("layout=elk-client")
  })
})
