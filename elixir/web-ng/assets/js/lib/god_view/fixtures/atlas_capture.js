import {worldTileIpc, worldTileKey} from "./world_tile_ipc"
import {decodeWorldTile} from "../world_tile_decode"

// Invented inventory for a real production-component screenshot, never a live
// export. Four rows of four clusters contain 64 devices each. The first four
// devices are individual glyphs; the other 60 share one collapsed aggregate.
export const atlasCaptureInventory = Array.from({length: 16}, (_, cluster) =>
  Array.from({length: 64}, (_, member) => ({
    id: `synthetic-${cluster}-${member}`, cluster, member,
    vlan: ["20", "30", "40", "40"][member % 4],
    availability: Math.floor(cluster / 4) === 0 ? "healthy" :
      member % 2 === 0 || Math.floor(cluster / 4) === 1 ? "unavailable" : "healthy",
    "tag:maintenance": member % 8 === 0 ? "true" : "false",
  }))).flat()

export const atlasCaptureQueryDescriptor = {entity_kind: "device", facets: [
  {key: "vlan", label: "Inventory VLAN", operators: ["eq"]},
  {key: "availability", label: "Availability", operators: ["eq"]},
  {key: "tag:maintenance", label: "Tag: maintenance", operators: ["eq"]},
], tag_keys: ["maintenance"], operators: {tag_key_prefix: false, ip_cidr: false}}

export function atlasCaptureMatches(device, expression) {
  if (expression.all) return expression.all.every(child => atlasCaptureMatches(device, child))
  if (expression.any) return expression.any.some(child => atlasCaptureMatches(device, child))
  if (expression.except) return !atlasCaptureMatches(device, expression.except)
  if (atlasCaptureQueryDescriptor.facets.some(facet => facet.key === expression.facet) && typeof expression.value === "string") return device[expression.facet] === expression.value
  throw new Error("unsupported_predicate")
}

const glyphs = Array.from({length: 16}, (_, cluster) => {
  const x = 64 + cluster % 4 * 128, y = 64 + Math.floor(cluster / 4) * 128
  const members = atlasCaptureInventory.filter(device => device.cluster === cluster)
  return [{id: `synthetic-aggregate-${cluster}`, x, y, members: members.slice(4)},
    ...members.slice(0, 4).map((device, index) => ({id: device.id, x: x + (index % 2 ? 26 : -26),
      y: y + (index < 2 ? -26 : 26), members: [device]}))]
}).flat()

export function atlasCaptureTile(z, x, y) {
  const width = 512 / 2 ** z
  const selected = glyphs.filter(glyph => glyph.x >= x * width && glyph.x < (x + 1) * width && glyph.y >= y * width && glyph.y < (y + 1) * width)
  const edges = selected.flatMap((glyph, target) => {
    if (glyph.members.length !== 1) return []
    const source = selected.findIndex(other => other.id === `synthetic-aggregate-${glyph.members[0].cluster}`)
    return source < 0 ? [] : [{source, target, details: {id: `synthetic-relation-${glyph.id}`, represented_count: 1, topology_class: "backbone", phase_start: 0, phase_end: 1}}]
  })
  const bytes = worldTileIpc({metadata: {z, x, y, origin_x: x * width * 32768, origin_y: y * width * 32768,
    coordinate_scale: width * 32768 / 65535, device_count: selected.reduce((sum, glyph) => sum + glyph.members.length, 0)},
    nodes: selected.map(glyph => ({x: Math.round((glyph.x / width - x) * 65535), y: Math.round((glyph.y / width - y) * 65535),
      label: `Access ${glyph.members[0].cluster + 1}-${glyph.members[0].member + 1}`, details: {id: glyph.id,
        type: glyph.members.length === 1 ? "device" : "aggregate", cluster_member_count: glyph.members.length}})), edges})
  return {bytes, geometry: {...decodeWorldTile(bytes, {...worldTileKey, z, x, y}), generation: 1}, populations: selected.map(glyph => glyph.members)}
}

export function atlasCaptureHealth(population) {
  const healthy = population.filter(device => device.availability === "healthy").length
  return [healthy, population.length - healthy, 0, healthy, population.length]
}
