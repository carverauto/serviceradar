import {describe, expect, it} from "vitest"
import {decodeWorldTile} from "./world_tile_decode"
import {worldTileIpc as tile, worldTileKey as key, worldTileRevision as revision} from "./fixtures/world_tile_ipc"


describe("world tile wire boundary", () => {
  it("uses the authoritative transform and typed membership/flow columns without parsing details", () => {
    const decoded = decodeWorldTile(tile(), {...key, revision})
    expect([...decoded.positions]).toEqual([256, 0, 512, 256])
    expect(decoded.nodes.map(node => [node.kind, node.count])).toEqual([["aggregate", 70000], ["boundary", 0]])
    expect(decoded.edges).toEqual([{id: "bundle:a", index: 0, source: 0, target: 1, count: 90000, start: 0.25, end: 0.75}])
    expect(decoded.columns.parsedDetailCounts()).toEqual({nodes: 0, edges: 0})
  })

  it.each([
    [{schema_version: 2}, "schema"],
    [{tile_revision: "bad"}, "revision"],
    [{origin_x: 1}, "transform"],
    [{coordinate_scale: "NaN"}, "transform"],
    [{node_count: 129}, "node_count"],
    [{device_count: 69999}, "device conservation"],
    [{max_nodes: 1}, "node budget"],
  ])("rejects incompatible metadata %j", (metadata, message) => {
    expect(() => decodeWorldTile(tile({metadata}), key)).toThrow(message)
  })

  it("rejects missing typed endpoints, out-of-range endpoints and actual byte overflow", () => {
    expect(() => decodeWorldTile(tile({omitColumns: ["edge_source"]}), key)).toThrow("edge_source")
    const invalid = tile({edges: [{source: 0, target: 2, details: {id: "bundle:a", represented_count: 1, phase_start: 0, phase_end: 1}}]})
    expect(() => decodeWorldTile(invalid, key)).toThrow("endpoint")
    expect(() => decodeWorldTile(new Uint8Array(262145), key)).toThrow("byte budget")
  })

  it("accepts a bounded empty batch and checks the requested revision", () => {
    const empty = tile({nodes: [], edges: [], metadata: {device_count: 0}})
    const decoded = decodeWorldTile(empty, key)
    expect(decoded.nodes).toEqual([])
    expect(decoded.edges).toEqual([])
    expect(() => decodeWorldTile(empty, {...key, revision: "b".repeat(64)})).toThrow("response revision")
  })
})
