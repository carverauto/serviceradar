// Shared ELK graph configuration for persisted world placement and browser scenes.
export function radialGraph(children, edges, {radius = 224, padding = 64} = {}) {
  return {
    id: "topology-overview",
    layoutOptions: {
      "elk.algorithm": "radial",
      "org.eclipse.elk.radial.centerOnRoot": "true",
      "org.eclipse.elk.radial.sorter": "ID",
      "org.eclipse.elk.radial.radius": String(radius),
      "org.eclipse.elk.radial.compactor": "NONE",
      "org.eclipse.elk.radial.wedgeCriteria": "LEAF_NUMBER",
      "elk.spacing.nodeNode": "96",
      "elk.padding": `[top=${padding},left=${padding},bottom=${padding},right=${padding}]`,
    },
    children,
    edges,
  }
}
