import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {test} from "node:test"
import {projectWorld} from "../lib/world.js"

const topology = JSON.parse(
  readFileSync(new URL("../../../priv/static/world-110m.json", import.meta.url), "utf8"),
)

test("projects land, a region, a point and an arc from the bundled topology", () => {
  const model = projectWorld(topology, {
    projection: "natural-earth",
    width: 960,
    height: 500,
    points: [{id: "sfo", lon: -122.4, lat: 37.8, label: "SFO", tone: "brand", size: 3}],
    regions: [{id: "840", label: "United States", tone: "info", level: 4}],
    arcs: [{id: "sfo-lhr", from: [-122.4, 37.8], to: [-0.45, 51.47], tone: "warning", weight: 2}],
  })

  assert.ok(model.land.length > 100)
  assert.equal(model.regions.length, 1)
  assert.equal(model.regions[0].id, "840")
  assert.equal(model.regions[0].level, 4)
  assert.ok(model.regions[0].d.startsWith("M"))
  assert.equal(model.points[0].id, "sfo")
  assert.equal(Number.isFinite(model.points[0].x), true)
  assert.match(model.arcs[0].d, /^M[\d.-]+,[\d.-]+ Q/)
  assert.equal(JSON.stringify(model).includes("mapbox"), false)
})

test("matches a region by Natural Earth name", () => {
  const model = projectWorld(topology, {
    projection: "equirectangular",
    width: 960,
    height: 500,
    points: [],
    regions: [{id: "Fiji", level: 1}],
    arcs: [],
  })
  assert.equal(model.regions.length, 1)
  assert.equal(model.regions[0].id, "Fiji")
})
