import {describe, expect, it} from "vitest"
import {atlasCaptureInventory, atlasCaptureMatches, atlasCaptureTile} from "./fixtures/atlas_capture"

describe("synthetic Atlas website capture facts", () => {
  it("projects the requested filter to exact aggregate and individual counts in bounded Arrow tiles", () => {
    const query = {all: [{any: [{facet: "vlan", value: "20"}, {facet: "vlan", value: "30"}]},
      {facet: "availability", value: "unavailable"}, {except: {facet: "tag:maintenance", value: "true"}}]}
    const matches = atlasCaptureInventory.filter(device => atlasCaptureMatches(device, query))
    // Independently counted residue classes: row 0 has no unavailable devices;
    // row 1 selects members 1, 4, 5 modulo 8; rows 2 and 3 select 4 modulo 8.
    expect(matches.length).toBe(4 * 24 + 8 * 8)
    expect(matches.filter(device => device.member < 4).map(device => device.id)).toEqual([
      "synthetic-4-1", "synthetic-5-1", "synthetic-6-1", "synthetic-7-1",
    ])
    const tile = atlasCaptureTile(0, 0, 0)
    expect(tile.geometry.nodes.length).toBe(80)
    expect(tile.geometry.edges.length).toBe(64)
    const aggregateCounts = tile.populations.filter(members => members.length > 1)
      .map(members => members.filter(device => atlasCaptureMatches(device, query)).length)
    expect(aggregateCounts).toEqual([0, 0, 0, 0, 23, 23, 23, 23, 8, 8, 8, 8, 8, 8, 8, 8])
    expect(new Set(tile.populations.flat().map(device => device.id)).size).toBe(1024)
    const children = [atlasCaptureTile(1, 0, 0), atlasCaptureTile(1, 1, 0), atlasCaptureTile(1, 0, 1), atlasCaptureTile(1, 1, 1)]
    expect(new Set(children.flatMap(child => child.populations.flat().map(device => device.id))).size).toBe(1024)
    expect(children.reduce((sum, child) => sum + child.populations.flat().filter(device => atlasCaptureMatches(device, query)).length, 0)).toBe(160)
  })
})
