import {worldTileIpc} from "./world_tile_ipc.js"
import {snapshotIpcBytes} from "./snapshot_ipc.js"

// Synthetic HTTP responses belong to the Node route owner, independent of page lifetime.
const devices = [
    {id: "invented-device-a", label: "Synthetic access", x: 192, y: 192},
    {id: "invented-device-b", label: "Synthetic endpoint", x: 208, y: 216},
  ]

export function transportTile({z, x, y}) {
  const width = 512 / 2 ** z
  const members = devices.filter(node => node.x >= x * width && node.x < (x + 1) * width && node.y >= y * width && node.y < (y + 1) * width)
  const clustered = z < 2 && members.length === 2
  const selected = clustered ? [{id: "invented-cluster", label: "2 devices", x: 200, y: 204}] : members
  return Array.from(worldTileIpc({
    metadata: {z, x, y, origin_x: x * width * 32768, origin_y: y * width * 32768,
      coordinate_scale: width * 32768 / 65535, device_count: members.length},
    nodes: selected.map(node => ({x: Math.round((node.x / width - x) * 65535), y: Math.round((node.y / width - y) * 65535),
      label: node.label, details: {id: node.id, type: clustered ? "aggregate" : "device", cluster_member_count: clustered ? 2 : 1}})),
    edges: selected.length === 2 ? [{source: 0, target: 1, details: {id: "invented-link", represented_count: 1, phase_start: 0, phase_end: 1}}] : [],
  }))
}

export function transportDetail() {
  return Array.from(snapshotIpcBytes({
    nodes: devices.map(node => ({state: 2, label: node.label, details: {id: node.id, type: "device", device_role: "access"}})),
    edges: [{source: 0, target: 1, flowPps: 120, flowPpsAb: 120, topologyClass: "backbone", evidenceClass: "direct-physical"}],
    metadataEntries: [["payload_kind", "detail"], ["layout_algorithm", "elk"]],
  }))
}
