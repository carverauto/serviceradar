function stringValue(value) {
  return value == null ? "" : String(value).trim()
}

function relationMetadata(edge) {
  return edge?.metadata && typeof edge.metadata === "object" ? edge.metadata : {}
}

function relationDetails(edge) {
  return edge?.details && typeof edge.details === "object" ? edge.details : {}
}

function metadataValue(metadata, key) {
  return metadata[key] ?? metadata[key.replaceAll("_", "-")]
}

export function canonicalSemanticRelationId(edge, sourceId, targetId) {
  const metadata = relationMetadata(edge)
  const details = relationDetails(edge)
  const signature = [
    stringValue(details.source_id) || stringValue(sourceId),
    stringValue(details.target_id) || stringValue(targetId),
    stringValue(edge?.topologyClass).toLowerCase() || "unknown",
    stringValue(edge?.kind).toLowerCase(),
    stringValue(edge?.protocol).toLowerCase(),
    stringValue(edge?.evidenceClass ?? edge?.evidence_class).toLowerCase(),
    stringValue(details.source_if_index ?? edge?.local_if_index_ab ?? edge?.local_if_index),
    stringValue(details.source_interface ?? edge?.local_if_name_ab ?? edge?.local_if_name),
    stringValue(details.target_if_index ?? edge?.local_if_index_ba ?? edge?.neighbor_if_index),
    stringValue(details.target_interface ?? edge?.local_if_name_ba ?? edge?.neighbor_if_name),
    stringValue(edge?.relationType ?? metadataValue(metadata, "relation_type")),
    stringValue(metadataValue(metadata, "topology_plane")),
    stringValue(edge?.confidenceTier ?? edge?.confidence_tier ?? metadataValue(metadata, "confidence_tier")),
    stringValue(edge?.confidenceReason ?? edge?.confidence_reason ?? metadataValue(metadata, "confidence_reason")),
  ]
  return `semantic:${JSON.stringify(signature)}`
}

export function topologyRelationId(edge, nodes) {
  const explicitId = stringValue(edge?.id) || stringValue(edge?.edge_id)
  if (explicitId !== "") return explicitId

  const sourceId = stringValue(nodes?.[Number(edge?.source)]?.id)
  const targetId = stringValue(nodes?.[Number(edge?.target)]?.id)
  return canonicalSemanticRelationId(edge, sourceId, targetId)
}
