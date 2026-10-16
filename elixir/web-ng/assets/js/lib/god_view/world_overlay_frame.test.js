import {describe, expect, it} from "vitest"
import {createHash} from "node:crypto"
import {decodeWorldOverlay} from "./world_overlay_frame"
import {telemetryFrame, telemetryGeometry, telemetryTime} from "./fixtures/world_overlay_frame"

describe("SRTO telemetry protocol", () => {
  it("preserves unknown versus zero, partial flow, coverage, and exact source timestamps", () => {
    const frame = telemetryFrame()
    const overlay = decodeWorldOverlay(frame, telemetryGeometry)
    expect(overlay.health.epoch).toBe("9007199254740993")
    expect(overlay.health.source).toEqual({source_status: "refreshing", reconciling: true, pending: 4,
      last_read_at: telemetryTime, reconciled_since: null, observed: 2, total: null})
    expect(overlay.healthAt(0)).toEqual({healthy: 0, unavailable: 0, unknown: 2, observed: 0, total: 2})
    expect(overlay.healthAt(1).healthy).toBe(1)
    expect(overlay.flowAt(0).forward).toMatchObject({status: "partial", animate: true, packets_per_second: null,
      observed_packets_per_second: 12.5, observed_octets_per_second: 0, octets_per_second: null,
      packet_interval: {previous_observed_at: telemetryTime, earliest_observed_at: telemetryTime + 1n, observed_at: telemetryTime + 2n}})
    expect(overlay.flowAt(0).reverse).toMatchObject({status: "unknown", animate: false, packet_interval: null, octet_interval: null})
    expect(overlay.flow.coverage).toEqual({rendered_relations: 3, selected_relations: 2, candidates_examined: 9,
      requested_pairs: 4, queried_pairs: 3, omitted_pairs: 1, scan_complete: false})
    expect(overlay.flow.query.since).toBe(telemetryTime - 900000000n)
    expect(overlay.retainedBytes).toBe(frame.byteLength + 8192 + 128)
    // The server encoder asserts the same independent wire digest.
    expect(createHash("sha256").update(frame).digest("hex")).toBe("585f159b722ef636a89239b7914464ebcc95fd1432723b05cc053323850b1bc8")
  })

  it("rejects mismatched receipts/rows, truncation, noncanonical nulls, and invalid rates before publication", () => {
    const frame = telemetryFrame()
    for (const geometry of [{...telemetryGeometry, revision: "other"}, {...telemetryGeometry, generation: 8},
      {...telemetryGeometry, nodes: []}, {...telemetryGeometry, edges: [{count: 4}]}]) {
      expect(() => decodeWorldOverlay(frame, geometry)).toThrow()
    }
    for (const mutate of [bytes => bytes.subarray(0, bytes.length - 1), bytes => {bytes[5] = 1; return bytes},
      bytes => {new DataView(bytes.buffer).setFloat64(bytes.length - 220 + 40, Infinity, true); return bytes},
      bytes => {new DataView(bytes.buffer).setBigUint64(bytes.length - 220 + 40, 0x7ff0000000000001n, true); return bytes}]) {
      expect(() => decodeWorldOverlay(mutate(frame.slice()), telemetryGeometry)).toThrow()
    }
  })
})
