import {snapshotIpcBytes} from "./snapshot_ipc"

export const worldTileKey = {layout_version: "00000000-0000-4000-8000-000000000478", z: 1, x: 1, y: 0}
export const worldTileRevision = "a".repeat(64)
export function worldTileIpc({metadata = {}, nodes, edges, ...options} = {}) {
  return snapshotIpcBytes({
    nodes: nodes ?? [
      {x: 0, y: 0, label: "West", details: {id: "aggregate:west", type: "aggregate", cluster_member_count: 70000}},
      {x: 65535, y: 65535, label: "East", details: {id: "boundary:east", type: "boundary", cluster_member_count: 0}},
    ],
    edges: edges ?? [{source: 0, target: 1, details: {id: "bundle:a", represented_count: 90000, phase_start: 0.25, phase_end: 0.75}}],
    metadataEntries: Object.entries({
      payload_kind: "tile", ...worldTileKey, tile_revision: worldTileRevision,
      coordinate_space: "tile-local-u16", world_extent: 2 ** 24,
      origin_x: 2 ** 23, origin_y: 0, coordinate_scale: (2 ** 23) / 65535,
      max_nodes: 128, max_edges: 256, max_encoded_bytes: 262144,
      device_count: 70000, internal_relations: 0, ...metadata,
    }).map(([name, value]) => [name, String(value)]),
    ...options,
  })
}

