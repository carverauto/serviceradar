const DEFAULT_VIEWPORT_WIDTH = 1280
const DEFAULT_VIEWPORT_HEIGHT = 720
const LANDSCAPE_ASPECT_THRESHOLD = 1.2
const COMPOUND_PADDING = 48
const SIBLING_SPACING = 96
const CROSS_AXIS_NODE_SPACING = 112
const COMPOUND_BETWEEN_LAYER_SPACING = 112
const BETWEEN_LAYER_ROUTE_CLEARANCE = 104
// ELK works in world units while route strokes and glyph halos remain fixed CSS
// pixels. Matching the sibling corridor keeps fitted routes clear of 20px halos.
// The endpoint-cluster summary node is named with the cluster id itself, and the compound
// group that holds it is keyed by that same cluster id -- so the container and one of its own
// children arrive at ELK sharing an identifier. `indexElkResult` keys by id, the child is
// indexed after its parent, and every lookup for the container then resolves to a 96x96 leaf
// instead of the box ELK actually laid out. That misreads every member as outside its group
// and resolves in-group edge origins against the wrong point, which is both halves of
// "invalid topology scene: node ... is outside group ...; route ... does not contact bound
// ELK port ...". Namespace the container so a node id can never shadow it.
const ELK_GROUP_CONTAINER_PREFIX = "elk-group:"

export function elkGroupContainerId(groupId) {
  return `${ELK_GROUP_CONTAINER_PREFIX}${groupId}`
}

export const ROUTE_CLEARANCE = 96
export const INTERSECTION_EPSILON = 0.01
const FIXED_RANDOM_SEED = 1729
const VISIBLE_ENDPOINT_SUMMARY_ENVELOPE = 448
const EXPANDED_GATEWAY_ENVELOPE = 112
const ENDPOINT_MEMBER_ENVELOPE = 96
const ORDINARY_NODE_ENVELOPE = 112
// Twice the rendered-route corridor keeps a centered trunk clear of the
// nearest branch when a manifold has an even branch count.
const MANIFOLD_SLOT_SPACING = BETWEEN_LAYER_ROUTE_CLEARANCE * 2
const PORTRAIT_PORT_SIDES = Object.freeze({source: "SOUTH", target: "NORTH"})
const LANDSCAPE_PORT_SIDES = Object.freeze({source: "EAST", target: "WEST"})

export const LANDSCAPE_PROFILE = Object.freeze({
  key: "landscape",
  direction: "RIGHT",
  targetAspectRatio: 1.6,
})

export const PORTRAIT_PROFILE = Object.freeze({
  key: "portrait",
  direction: "DOWN",
  targetAspectRatio: 0.75,
})

function finiteNonNegative(value) {
  const number = Number(value)
  return Number.isFinite(number) ? Math.max(0, number) : 0
}

export function viewportProfileForSize(width, height, safeInsets = {}) {
  const viewportWidth = Number.isFinite(Number(width)) && Number(width) > 0
    ? Number(width)
    : DEFAULT_VIEWPORT_WIDTH
  const viewportHeight = Number.isFinite(Number(height)) && Number(height) > 0
    ? Number(height)
    : DEFAULT_VIEWPORT_HEIGHT
  const usableWidth = Math.max(
    1,
    viewportWidth - finiteNonNegative(safeInsets?.left) - finiteNonNegative(safeInsets?.right),
  )
  const usableHeight = Math.max(
    1,
    viewportHeight - finiteNonNegative(safeInsets?.top) - finiteNonNegative(safeInsets?.bottom),
  )

  return usableWidth / usableHeight >= LANDSCAPE_ASPECT_THRESHOLD
    ? LANDSCAPE_PROFILE
    : PORTRAIT_PROFILE
}

function elkLayoutOptions(profile, kind) {
  return {
    "elk.algorithm": "layered",
    "elk.hierarchyHandling": "INCLUDE_CHILDREN",
    "elk.edgeRouting": "ORTHOGONAL",
    "elk.direction": profile.direction,
    "elk.aspectRatio": String(profile.targetAspectRatio),
    "elk.randomSeed": String(FIXED_RANDOM_SEED),
    "elk.spacing.nodeNode": String(CROSS_AXIS_NODE_SPACING),
    "elk.spacing.edgeNode": String(BETWEEN_LAYER_ROUTE_CLEARANCE),
    "elk.spacing.edgeEdge": String(ROUTE_CLEARANCE * 2),
    "elk.spacing.componentComponent": String(SIBLING_SPACING),
    "elk.layered.spacing.nodeNodeBetweenLayers": String(
      kind === "endpoint-group" ? COMPOUND_BETWEEN_LAYER_SPACING : SIBLING_SPACING,
    ),
    "elk.layered.spacing.edgeNodeBetweenLayers": String(BETWEEN_LAYER_ROUTE_CLEARANCE),
    "elk.layered.spacing.edgeEdgeBetweenLayers": String(ROUTE_CLEARANCE * 2),
    "elk.layered.crossingMinimization.strategy": "LAYER_SWEEP",
    "elk.layered.nodePlacement.strategy": "NETWORK_SIMPLEX",
    "elk.padding": `[top=${COMPOUND_PADDING},left=${COMPOUND_PADDING},bottom=${COMPOUND_PADDING},right=${COMPOUND_PADDING}]`,
    ...(kind ? {"serviceradar.kind": kind} : {}),
  }
}

function dimensionsForNode(node) {
  // A collapsed summary can render a 45.875px halo. Its larger invisible ELK
  // envelope prevents fitted routes from entering that fixed-pixel glyph.
  if (node.kind === "endpoint-summary") {
    const envelope = node.render === false
      ? EXPANDED_GATEWAY_ENVELOPE
      : VISIBLE_ENDPOINT_SUMMARY_ENVELOPE
    return {width: envelope, height: envelope}
  }
  if (node.kind === "endpoint-member") {
    return {width: ENDPOINT_MEMBER_ENVELOPE, height: ENDPOINT_MEMBER_ENVELOPE}
  }
  return {width: ORDINARY_NODE_ENVELOPE, height: ORDINARY_NODE_ENVELOPE}
}

function elkLeaf(node, manifoldSpecs = [], directPortSpecs = []) {
  const ports = [
    ...manifoldSpecs.map((spec) => ({id: spec.glyphPortId, side: spec.branchSide})),
    ...directPortSpecs.map((spec) => ({id: spec.id, side: spec.side})),
  ]
  return {
    id: node.id,
    ...dimensionsForNode(node),
    ...(ports.length > 0 ? {
      ports: ports.map((port) => ({
        id: port.id,
        width: 0,
        height: 0,
        layoutOptions: {"elk.port.side": port.side},
      })),
    } : {}),
    layoutOptions: {
      "serviceradar.kind": node.kind,
      "serviceradar.render": String(node.render),
      ...(ports.length > 0 ? {"elk.portConstraints": "FIXED_SIDE"} : {}),
    },
  }
}

function relationEdge(relation, render) {
  return {
    id: relation.id,
    sources: [relation.sourcePortId || relation.sourceId],
    targets: [relation.targetPortId || relation.targetId],
    layoutOptions: {
      "serviceradar.render": String(render),
    },
  }
}

function manifoldId(nodeId, endpoint) {
  return `manifold:${nodeId}:${endpoint}`
}

function relationPortId(relationId, nodeId) {
  return `port:${nodeId}:${relationId}`
}

function manifoldBranchPortId(relationId, nodeId, endpoint) {
  return `${manifoldId(nodeId, endpoint)}:branch:${relationId}`
}

function manifoldTrunkPortId(nodeId, endpoint) {
  return `${manifoldId(nodeId, endpoint)}:trunk`
}

function manifoldGlyphPortId(nodeId, endpoint) {
  return `${manifoldId(nodeId, endpoint)}:glyph`
}

function manifoldTrunkEdgeId(nodeId, endpoint) {
  return `${manifoldId(nodeId, endpoint)}:trunk-edge`
}

function elkManifoldBindings(ownedRelations, profile) {
  const relationSpecsByRole = new Map()
  const bindingsByRelationId = new Map()
  for (const {relation, render} of ownedRelations) {
    // Layout-only packing relations are invisible constraints. Let layered ELK
    // choose their implicit ports; reserving fixed-pixel visual corridors for
    // them needlessly inflates expanded endpoint compounds.
    if (!render) continue
    for (const [nodeId, endpoint] of [
      [relation.sourceId, "source"],
      [relation.targetId, "target"],
    ]) {
      const roleKey = `${nodeId}\u0000${endpoint}`
      const current = relationSpecsByRole.get(roleKey) || []
      current.push({
        relationId: relation.id,
        endpoint,
        nodeId,
      })
      relationSpecsByRole.set(roleKey, current)
    }
  }

  const sides = profile?.direction === "DOWN" ? PORTRAIT_PORT_SIDES : LANDSCAPE_PORT_SIDES
  const manifoldsByNodeId = new Map()
  const directPortsByNodeId = new Map()
  for (const specs of relationSpecsByRole.values()) {
    specs.sort((left, right) => left.relationId.localeCompare(right.relationId))
    const {nodeId, endpoint} = specs[0]
    const branchSide = sides[endpoint]
    if (specs.length === 1) {
      const relationId = specs[0].relationId
      const directPort = {id: relationPortId(relationId, nodeId), relationId, endpoint, side: branchSide}
      const currentPorts = directPortsByNodeId.get(nodeId) || []
      currentPorts.push(directPort)
      directPortsByNodeId.set(nodeId, currentPorts)
      const binding = bindingsByRelationId.get(relationId) || {}
      binding[endpoint === "source" ? "sourcePortId" : "targetPortId"] = directPort.id
      bindingsByRelationId.set(relationId, binding)
      continue
    }
    const trunkSide = profile?.direction === "DOWN"
      ? (branchSide === "SOUTH" ? "NORTH" : "SOUTH")
      : (branchSide === "EAST" ? "WEST" : "EAST")
    const manifold = {
      id: manifoldId(nodeId, endpoint),
      nodeId,
      endpoint,
      branchSide,
      trunkSide,
      glyphPortId: manifoldGlyphPortId(nodeId, endpoint),
      trunkPortId: manifoldTrunkPortId(nodeId, endpoint),
      trunkEdgeId: manifoldTrunkEdgeId(nodeId, endpoint),
      branches: specs.map((spec) => ({
        ...spec,
        id: manifoldBranchPortId(spec.relationId, nodeId, endpoint),
      })),
    }
    const current = manifoldsByNodeId.get(nodeId) || []
    current.push(manifold)
    manifoldsByNodeId.set(nodeId, current)
    for (const relation of manifold.branches) {
      const binding = bindingsByRelationId.get(relation.relationId) || {}
      binding[endpoint === "source" ? "sourcePortId" : "targetPortId"] = relation.id
      bindingsByRelationId.set(relation.relationId, binding)
    }
  }
  for (const [nodeId, specs] of manifoldsByNodeId) {
    manifoldsByNodeId.set(nodeId, specs.sort((left, right) => left.endpoint.localeCompare(right.endpoint)))
  }
  for (const [nodeId, specs] of directPortsByNodeId) {
    directPortsByNodeId.set(nodeId, specs.sort((left, right) => left.id.localeCompare(right.id)))
  }
  return {bindingsByRelationId, manifoldsByNodeId, directPortsByNodeId}
}

function elkFanoutManifold(spec, profile) {
  const crossAxisSize = (spec.branches.length + 1) * MANIFOLD_SLOT_SPACING
  return {
    id: spec.id,
    width: profile?.direction === "DOWN" ? crossAxisSize : 0,
    height: profile?.direction === "DOWN" ? 0 : crossAxisSize,
    ports: [
      {
        id: spec.trunkPortId,
        width: 0,
        height: 0,
        layoutOptions: {"elk.port.side": spec.trunkSide},
      },
      ...spec.branches.map((branch) => ({
        id: branch.id,
        width: 0,
        height: 0,
        layoutOptions: {"elk.port.side": spec.branchSide},
      })),
    ],
    layoutOptions: {
      "serviceradar.kind": "fanout-manifold",
      "serviceradar.node-id": spec.nodeId,
      "serviceradar.endpoint": spec.endpoint,
      "elk.portConstraints": "FIXED_SIDE",
    },
  }
}

function elkFanoutTrunk(spec) {
  const sourceId = spec.endpoint === "source" ? spec.glyphPortId : spec.trunkPortId
  const targetId = spec.endpoint === "source" ? spec.trunkPortId : spec.glyphPortId
  return {
    id: spec.trunkEdgeId,
    sources: [sourceId],
    targets: [targetId],
    layoutOptions: {
      "serviceradar.kind": "fanout-trunk",
      "serviceradar.node-id": spec.nodeId,
      "serviceradar.endpoint": spec.endpoint,
      "serviceradar.render": "auxiliary",
    },
  }
}

function compoundPackingLaneCount(memberCount, profile) {
  if (memberCount <= 1) return Math.max(0, memberCount)
  const targetAspectRatio = Math.max(0.1, Number(profile?.targetAspectRatio) || 1)
  const crossAxisCount = profile?.direction === "DOWN"
    ? Math.sqrt(memberCount * targetAspectRatio)
    : Math.sqrt(memberCount / targetAspectRatio)
  return Math.max(1, Math.min(memberCount, Math.ceil(crossAxisCount)))
}

function packedLayoutRelations(sceneInput, profile) {
  const relations = [...(sceneInput?.layoutRelations || [])]
  const relationByTarget = new Map(relations.map((relation) => [relation.targetId, relation]))
  const packedRelationIds = new Set()
  const packed = []

  // A gateway star forces every member into one layered rank. Rewire only
  // non-rendered packing constraints into aspect-shaped lanes; rendered
  // topology relations and their endpoint bindings remain untouched.
  for (const group of [...(sceneInput?.groups || [])]
    .filter((candidate) => candidate.expanded)
    .sort((left, right) => left.id.localeCompare(right.id))) {
    const memberIds = [...(group.memberIds || [])].sort((left, right) => left.localeCompare(right))
    const laneCount = compoundPackingLaneCount(memberIds.length, profile)
    memberIds.forEach((memberId, index) => {
      const relation = relationByTarget.get(memberId)
      if (!relation) return
      const sourceId = index < laneCount ? group.gatewayId : memberIds[index - laneCount]
      packed.push({...relation, sourceId})
      packedRelationIds.add(relation.id)
    })
  }

  return [
    ...packed,
    ...relations.filter((relation) => !packedRelationIds.has(relation.id)),
  ]
}

export function buildElkSceneGraph(sceneInput, profile = LANDSCAPE_PROFILE) {
  const nodes = [...(sceneInput?.nodes || [])].sort((left, right) => left.id.localeCompare(right.id))
  const nodeById = new Map(nodes.map((node) => [node.id, node]))
  const expandedGroups = [...(sceneInput?.groups || [])]
    .filter((group) => group.expanded)
    .sort((left, right) => left.id.localeCompare(right.id))
  const expandedGroupIds = new Set(expandedGroups.map((group) => group.id))
  const packedRelations = packedLayoutRelations(sceneInput, profile)
  const groupIdByNodeId = new Map()
  const groupedNodeIds = new Set()

  for (const group of expandedGroups) {
    groupIdByNodeId.set(group.gatewayId, group.id)
    for (const memberId of group.memberIds || []) groupIdByNodeId.set(memberId, group.id)
  }

  const ownedRelations = [
    ...(sceneInput?.renderedRelations || []).map((relation) => ({relation, render: true})),
    ...packedRelations.map((relation) => ({relation, render: false})),
  ].map((owned) => {
    const sourceGroupId = groupIdByNodeId.get(owned.relation.sourceId)
    const targetGroupId = groupIdByNodeId.get(owned.relation.targetId)
    return {
      ...owned,
      ownerId: sourceGroupId && sourceGroupId === targetGroupId ? sourceGroupId : null,
    }
  })
  const {
    bindingsByRelationId,
    manifoldsByNodeId,
    directPortsByNodeId,
  } = elkManifoldBindings(ownedRelations, profile)
  const portedRelations = ownedRelations.map((owned) => ({
    ...owned,
    relation: {
      ...owned.relation,
      ...(bindingsByRelationId.get(owned.relation.id) || {}),
    },
  }))

  const compoundChildren = expandedGroups.map((group) => {
    const childIds = [group.gatewayId, ...(group.memberIds || [])]
      .filter((id) => nodeById.has(id))
      .sort((left, right) => left.localeCompare(right))
    childIds.forEach((id) => groupedNodeIds.add(id))
    const groupRelations = portedRelations.filter((owned) => owned.ownerId === group.id)
    const manifoldSpecs = childIds.flatMap((id) => manifoldsByNodeId.get(id) || [])

    return {
      id: elkGroupContainerId(group.id),
      layoutOptions: elkLayoutOptions(profile, "endpoint-group"),
      children: [
        ...childIds.map((id) => elkLeaf(
          nodeById.get(id),
          manifoldsByNodeId.get(id) || [],
          directPortsByNodeId.get(id) || [],
        )),
        ...manifoldSpecs.map((spec) => elkFanoutManifold(spec, profile)),
      ].sort((left, right) => left.id.localeCompare(right.id)),
      edges: [
        ...groupRelations.map(({relation, render}) => relationEdge(relation, render)),
        ...manifoldSpecs.map(elkFanoutTrunk),
      ].sort((left, right) => left.id.localeCompare(right.id)),
    }
  })

  const rootNodes = nodes
    .filter((node) => !groupedNodeIds.has(node.id) && !expandedGroupIds.has(node.groupId))
  const rootManifoldSpecs = rootNodes.flatMap((node) => manifoldsByNodeId.get(node.id) || [])
  const rootLeaves = [
    ...rootNodes.map((node) => elkLeaf(
      node,
      manifoldsByNodeId.get(node.id) || [],
      directPortsByNodeId.get(node.id) || [],
    )),
    ...rootManifoldSpecs.map((spec) => elkFanoutManifold(spec, profile)),
  ]
  const edges = [
    ...portedRelations
      .filter((owned) => owned.ownerId === null)
      .map(({relation, render}) => relationEdge(relation, render)),
    ...rootManifoldSpecs.map(elkFanoutTrunk),
  ].sort((left, right) => left.id.localeCompare(right.id))

  return {
    id: "god-view-root",
    layoutOptions: elkLayoutOptions(profile),
    children: [...rootLeaves, ...compoundChildren].sort((left, right) => left.id.localeCompare(right.id)),
    edges,
  }
}

function finiteOrNaN(value) {
  const number = Number(value)
  return Number.isFinite(number) ? number : Number.NaN
}

function indexElkResult(node, parentOrigin, elements, edgeOwners) {
  if (!node || typeof node !== "object") return
  const origin = {
    x: parentOrigin.x + finiteOrNaN(node.x ?? 0),
    y: parentOrigin.y + finiteOrNaN(node.y ?? 0),
  }
  elements.set(node.id, {node, origin})

  for (const edge of node.edges || []) {
    const candidates = edgeOwners.get(edge.id) || []
    candidates.push({edge, ownerId: node.id})
    edgeOwners.set(edge.id, candidates)
  }
  for (const port of node.ports || []) {
    const portOrigin = {
      x: origin.x + finiteOrNaN(port.x ?? 0),
      y: origin.y + finiteOrNaN(port.y ?? 0),
    }
    elements.set(port.id, {node: port, origin: portOrigin, parentId: node.id})
  }
  for (const child of node.children || []) indexElkResult(child, origin, elements, edgeOwners)
}

function decodedPoints(edge, ownerId, elements) {
  if (!edge || !Array.isArray(edge.sections) || edge.sections.length !== 1) return []
  const section = edge.sections[0]
  const origin = elements.get(edge.container || ownerId)?.origin || {x: Number.NaN, y: Number.NaN}
  const rawPoints = [section?.startPoint, ...(section?.bendPoints || []), section?.endPoint]

  return rawPoints.map((point) => ({
    x: origin.x + finiteOrNaN(point?.x),
    y: origin.y + finiteOrNaN(point?.y),
  }))
}

function renderedEdgeEndpointBindingError(edge, relation, binding, elements) {
  if (!edge) return null
  const expectedSource = binding?.sourcePortId || relation.sourceId
  const expectedTarget = binding?.targetPortId || relation.targetId
  const sourcesMatch = Array.isArray(edge.sources)
    && edge.sources.length === 1
    && edge.sources[0] === expectedSource
  const targetsMatch = Array.isArray(edge.targets)
    && edge.targets.length === 1
    && edge.targets[0] === expectedTarget
  const endpointsExist = elements.has(expectedSource) && elements.has(expectedTarget)
  if (sourcesMatch && targetsMatch && endpointsExist) return null
  return `route ${relation.id} has invalid ELK endpoint binding; expected exactly ${expectedSource} -> ${expectedTarget}`
}

function renderedEdgeEndpointGeometryError(points, relation, binding, elements) {
  if (!Array.isArray(points) || points.length < 2) return null
  const sourcePortId = binding?.sourcePortId || relation.sourceId
  const targetPortId = binding?.targetPortId || relation.targetId
  if (!pointsContact(points[0], decodedElementCenter(sourcePortId, elements))) {
    return `route ${relation.id} section source does not contact bound ELK port ${sourcePortId}`
  }
  if (!pointsContact(points.at(-1), decodedElementCenter(targetPortId, elements))) {
    return `route ${relation.id} section target does not contact bound ELK port ${targetPortId}`
  }
  return null
}

function decodedRenderedRoute(relation, binding, elements, edgeOwners) {
  const renderedCandidates = edgeOwners.get(relation.id) || []
  const rendered = renderedCandidates.length === 1 ? renderedCandidates[0] : null
  const points = decodedPoints(rendered?.edge, rendered?.ownerId, elements)
  const bindingError = renderedCandidates.length === 1
    ? renderedEdgeEndpointBindingError(rendered?.edge, relation, binding, elements)
    : `route ${relation.id} must decode from exactly one continuous section`
  return {
    points,
    endpointBindingError: bindingError || renderedEdgeEndpointGeometryError(
      points,
      relation,
      binding,
      elements,
    ),
  }
}

function decodedElementCenter(elementId, elements) {
  const decoded = elements.get(elementId)
  const width = finiteOrNaN(decoded?.node?.width ?? 0)
  const height = finiteOrNaN(decoded?.node?.height ?? 0)
  return {
    x: finiteOrNaN(decoded?.origin?.x) + (width / 2),
    y: finiteOrNaN(decoded?.origin?.y) + (height / 2),
  }
}

function manifoldBranchJunctionId(manifoldSpec, routeId) {
  return `${manifoldSpec.id}:junction:${routeId}`
}

function manifoldTrunkJunctionId(manifoldSpec) {
  return `${manifoldSpec.id}:junction:trunk`
}

function manifoldGlyphJunctionId(manifoldSpec) {
  return `${manifoldSpec.id}:junction:glyph`
}

function decodedManifolds(sceneInput, elements, edgeOwners) {
  const rendered = (sceneInput?.renderedRelations || []).map((relation) => ({relation, render: true}))
  const {manifoldsByNodeId} = elkManifoldBindings(rendered, LANDSCAPE_PROFILE)
  return [...manifoldsByNodeId.values()]
    .flat()
    .map((spec) => {
      const decoded = elements.get(spec.id)
      const origin = decoded?.origin || {x: Number.NaN, y: Number.NaN}
      const width = finiteOrNaN(decoded?.node?.width)
      const height = finiteOrNaN(decoded?.node?.height)
      const expectedCrossAxis = (spec.branches.length + 1) * MANIFOLD_SLOT_SPACING
      const dimensionContractMatches = (
        Math.abs(width) <= INTERSECTION_EPSILON
          && Math.abs(height - expectedCrossAxis) <= INTERSECTION_EPSILON
      ) || (
        Math.abs(height) <= INTERSECTION_EPSILON
          && Math.abs(width - expectedCrossAxis) <= INTERSECTION_EPSILON
      )
      const nodeContact = decodedElementCenter(spec.glyphPortId, elements)
      const trunkContact = decodedElementCenter(spec.trunkPortId, elements)
      const branchContacts = spec.branches.map((branch) => ({
        routeId: branch.relationId,
        junctionId: manifoldBranchJunctionId(spec, branch.relationId),
        point: decodedElementCenter(branch.id, elements),
      }))
      const railContacts = [trunkContact, ...branchContacts.map((branch) => branch.point)]
      const railPoints = width > height
        ? [
            {x: Math.min(...railContacts.map((point) => point.x)), y: origin.y},
            {x: Math.max(...railContacts.map((point) => point.x)), y: origin.y},
          ]
        : [
            {x: origin.x, y: Math.min(...railContacts.map((point) => point.y))},
            {x: origin.x, y: Math.max(...railContacts.map((point) => point.y))},
          ]
      const trunkCandidates = edgeOwners.get(spec.trunkEdgeId) || []
      const trunk = trunkCandidates.length === 1 ? trunkCandidates[0] : null
      const expectedSource = spec.endpoint === "source" ? spec.glyphPortId : spec.trunkPortId
      const expectedTarget = spec.endpoint === "source" ? spec.trunkPortId : spec.glyphPortId
      const bindingMatches = Array.isArray(trunk?.edge?.sources)
        && trunk.edge.sources.length === 1
        && trunk.edge.sources[0] === expectedSource
        && Array.isArray(trunk?.edge?.targets)
        && trunk.edge.targets.length === 1
        && trunk.edge.targets[0] === expectedTarget
      const relationsById = new Map((sceneInput?.renderedRelations || []).map((relation) => [relation.id, relation]))
      const relationIds = Array.from(new Set(spec.branches.flatMap(
        (branch) => relationsById.get(branch.relationId)?.relationIds || [],
      ))).sort((left, right) => left.localeCompare(right))
      return {
        id: spec.id,
        nodeId: spec.nodeId,
        endpoint: spec.endpoint,
        nodeContact,
        trunkContact,
        trunkPoints: decodedPoints(trunk?.edge, trunk?.ownerId, elements),
        railPoints,
        branchContacts,
        relationIds,
        semanticRouteIds: spec.branches.map((branch) => branch.relationId),
        ...(!dimensionContractMatches ? {
          geometryContractError: `manifold ${spec.id} must retain one zero flow axis and exact ${expectedCrossAxis} cross-axis length`,
        } : {}),
        ...(trunkCandidates.length !== 1 || !bindingMatches
          ? {endpointBindingError: `manifold ${spec.id} must decode from exactly one correctly bound ELK trunk edge`}
          : {}),
      }
    })
    .sort((left, right) => left.id.localeCompare(right.id))
}

function boxForNode(node) {
  return {
    minX: node.center.x - node.width / 2,
    minY: node.center.y - node.height / 2,
    maxX: node.center.x + node.width / 2,
    maxY: node.center.y + node.height / 2,
  }
}

function sceneBounds(nodes, groups, routes) {
  const values = []
  for (const node of nodes) values.push(boxForNode(node))
  for (const group of groups) values.push(group.bounds)
  for (const route of routes) {
    for (const point of route.points) {
      values.push({minX: point.x, minY: point.y, maxX: point.x, maxY: point.y})
    }
  }

  if (values.length === 0) return {minX: 0, minY: 0, maxX: 0, maxY: 0}
  return {
    minX: Math.min(...values.map((value) => value.minX)),
    minY: Math.min(...values.map((value) => value.minY)),
    maxX: Math.max(...values.map((value) => value.maxX)),
    maxY: Math.max(...values.map((value) => value.maxY)),
  }
}

export function decodeElkScene(elkResult, sceneInput) {
  const elements = new Map()
  const edgeOwners = new Map()
  indexElkResult(elkResult, {x: 0, y: 0}, elements, edgeOwners)

  const nodes = [...(sceneInput?.nodes || [])]
    .map((sceneNode) => {
      const decoded = elements.get(sceneNode.id)
      const width = finiteOrNaN(decoded?.node?.width)
      const height = finiteOrNaN(decoded?.node?.height)
      const required = dimensionsForNode(sceneNode)
      const undersized = Number.isFinite(width) && Number.isFinite(height)
        && (width + INTERSECTION_EPSILON < required.width
          || height + INTERSECTION_EPSILON < required.height)
      return {
        id: sceneNode.id,
        center: {
          x: decoded?.origin.x + width / 2,
          y: decoded?.origin.y + height / 2,
        },
        width,
        height,
        groupId: sceneNode.groupId,
        render: sceneNode.render,
        ...(undersized ? {
          geometryContractError: `node ${sceneNode.id} is smaller than its required ${required.width} x ${required.height} ELK envelope`,
        } : {}),
      }
    })
    .sort((left, right) => left.id.localeCompare(right.id))

  const groups = [...(sceneInput?.groups || [])]
    .filter((group) => group.expanded)
    .map((group) => {
      const decoded = elements.get(elkGroupContainerId(group.id))
      const width = finiteOrNaN(decoded?.node?.width)
      const height = finiteOrNaN(decoded?.node?.height)
      const originX = finiteOrNaN(decoded?.origin?.x)
      const originY = finiteOrNaN(decoded?.origin?.y)
      return {
        id: group.id,
        bounds: {
          minX: originX,
          minY: originY,
          maxX: originX + width,
          maxY: originY + height,
        },
        memberIds: [...(group.memberIds || [])].sort((left, right) => left.localeCompare(right)),
        anchorId: group.anchorId,
        gatewayId: group.gatewayId,
      }
    })
    .sort((left, right) => left.id.localeCompare(right.id))

  const rendered = (sceneInput?.renderedRelations || []).map((relation) => ({relation, render: true}))
  const {bindingsByRelationId} = elkManifoldBindings(rendered, LANDSCAPE_PROFILE)
  const manifolds = decodedManifolds(sceneInput, elements, edgeOwners)
  const manifoldById = new Map(manifolds.map((manifold) => [manifold.id, manifold]))
  const routes = [...(sceneInput?.renderedRelations || [])]
    .map((relation) => {
      const binding = bindingsByRelationId.get(relation.id) || {}
      const decoded = decodedRenderedRoute(relation, binding, elements, edgeOwners)
      const sourceManifold = manifoldById.get(manifoldId(relation.sourceId, "source"))
      const targetManifold = manifoldById.get(manifoldId(relation.targetId, "target"))
      const sourceJunctionId = sourceManifold
        ? manifoldBranchJunctionId(sourceManifold, relation.id)
        : relationPortId(relation.id, relation.sourceId)
      const targetJunctionId = targetManifold
        ? manifoldBranchJunctionId(targetManifold, relation.id)
        : relationPortId(relation.id, relation.targetId)
      return {
        id: relation.id,
        sourceId: relation.sourceId,
        targetId: relation.targetId,
        sourceContactId: sourceJunctionId,
        targetContactId: targetJunctionId,
        ...(sourceManifold ? {sourceManifoldId: sourceManifold.id} : {}),
        ...(targetManifold ? {targetManifoldId: targetManifold.id} : {}),
        points: decoded.points,
        junctions: [
          ...(sourceManifold && decoded.points[0]
            ? [{id: sourceJunctionId, point: decoded.points[0]}]
            : []),
          ...(targetManifold && decoded.points.at(-1)
            ? [{id: targetJunctionId, point: decoded.points.at(-1)}]
            : []),
        ],
        relationIds: [...(relation.relationIds || [])].sort((left, right) => left.localeCompare(right)),
        metadata: relation.metadata && typeof relation.metadata === "object" ? {...relation.metadata} : {},
        ...(decoded.endpointBindingError ? {endpointBindingError: decoded.endpointBindingError} : {}),
      }
    })
    .sort((left, right) => left.id.localeCompare(right.id))

  const manifoldRoutes = manifolds.flatMap((manifold) => {
    const trunkJunctionId = manifoldTrunkJunctionId(manifold)
    const nodeJunctionId = manifoldGlyphJunctionId(manifold)
    const trunkSourceContactId = manifold.endpoint === "source" ? nodeJunctionId : trunkJunctionId
    const trunkTargetContactId = manifold.endpoint === "source" ? trunkJunctionId : nodeJunctionId
    const trunk = {
      id: `${manifold.id}:trunk`,
      sourceId: manifold.nodeId,
      targetId: manifold.nodeId,
      sourceContactId: trunkSourceContactId,
      targetContactId: trunkTargetContactId,
      points: manifold.trunkPoints,
      relationIds: manifold.relationIds,
      semanticRouteIds: manifold.semanticRouteIds,
      incidentNodeIds: [manifold.nodeId],
      auxiliary: true,
      kind: "manifold-trunk",
      junctions: [
        {id: nodeJunctionId, point: manifold.nodeContact},
        {id: trunkJunctionId, point: manifold.trunkContact},
        ...manifold.branchContacts
          .filter((branch) => pointsContact(branch.point, manifold.trunkContact))
          .map((branch) => ({id: branch.junctionId, point: branch.point})),
      ],
      metadata: {},
    }
    const rail = {
      id: `${manifold.id}:rail`,
      sourceId: manifold.nodeId,
      targetId: manifold.nodeId,
      sourceContactId: `${manifold.id}:rail:start`,
      targetContactId: `${manifold.id}:rail:end`,
      points: manifold.railPoints,
      relationIds: manifold.relationIds,
      semanticRouteIds: manifold.semanticRouteIds,
      incidentNodeIds: [manifold.nodeId],
      auxiliary: true,
      kind: "manifold-rail",
      junctions: [
        {id: trunkJunctionId, point: manifold.trunkContact},
        ...manifold.branchContacts.map((branch) => ({id: branch.junctionId, point: branch.point})),
      ],
      metadata: {},
    }
    return [trunk, rail]
  }).sort((left, right) => left.id.localeCompare(right.id))
  const physicalRoutes = [...routes, ...manifoldRoutes]

  return {
    nodes,
    groups,
    routes,
    manifolds,
    physicalRoutes,
    bounds: sceneBounds(nodes, groups, physicalRoutes),
  }
}

function finiteBox(box) {
  return [box?.minX, box?.minY, box?.maxX, box?.maxY].every(Number.isFinite)
}

function boxesOverlap(left, right) {
  return (
    Math.min(left.maxX, right.maxX) - Math.max(left.minX, right.minX) > INTERSECTION_EPSILON &&
    Math.min(left.maxY, right.maxY) - Math.max(left.minY, right.minY) > INTERSECTION_EPSILON
  )
}

function boxContains(outer, inner) {
  return (
    inner.minX >= outer.minX - INTERSECTION_EPSILON &&
    inner.minY >= outer.minY - INTERSECTION_EPSILON &&
    inner.maxX <= outer.maxX + INTERSECTION_EPSILON &&
    inner.maxY <= outer.maxY + INTERSECTION_EPSILON
  )
}

function segmentIntersectsOpenBox(start, end, box, clearance = ROUTE_CLEARANCE) {
  const interior = {
    minX: box.minX - clearance + INTERSECTION_EPSILON,
    minY: box.minY - clearance + INTERSECTION_EPSILON,
    maxX: box.maxX + clearance - INTERSECTION_EPSILON,
    maxY: box.maxY + clearance - INTERSECTION_EPSILON,
  }
  let lower = 0
  let upper = 1

  for (const axis of ["x", "y"]) {
    const delta = end[axis] - start[axis]
    const minimum = interior[`min${axis.toUpperCase()}`]
    const maximum = interior[`max${axis.toUpperCase()}`]
    if (Math.abs(delta) <= INTERSECTION_EPSILON) {
      if (start[axis] <= minimum || start[axis] >= maximum) return false
      continue
    }

    const first = (minimum - start[axis]) / delta
    const second = (maximum - start[axis]) / delta
    lower = Math.max(lower, Math.min(first, second))
    upper = Math.min(upper, Math.max(first, second))
    if (lower >= upper - INTERSECTION_EPSILON) return false
  }

  return upper > INTERSECTION_EPSILON && lower < 1 - INTERSECTION_EPSILON
}

function routeIntersectsBox(route, box, clearance = ROUTE_CLEARANCE) {
  for (let index = 1; index < route.points.length; index += 1) {
    if (segmentIntersectsOpenBox(
      route.points[index - 1],
      route.points[index],
      box,
      clearance,
    )) return true
  }
  return false
}

function orientation(start, end, point) {
  return ((end.x - start.x) * (point.y - start.y))
    - ((end.y - start.y) * (point.x - start.x))
}

function segmentLength(start, end) {
  return Math.hypot(end.x - start.x, end.y - start.y)
}

function signedPerpendicularDistance(start, end, point) {
  const length = segmentLength(start, end)
  if (length <= INTERSECTION_EPSILON) return Number.NaN
  return orientation(start, end, point) / length
}

function pointsContact(first, second) {
  return Math.hypot(second.x - first.x, second.y - first.y) <= INTERSECTION_EPSILON
}

function pointContactsSegment(point, start, end) {
  const length = segmentLength(start, end)
  if (length <= INTERSECTION_EPSILON) return pointsContact(point, start)
  if (Math.abs(signedPerpendicularDistance(start, end, point)) > INTERSECTION_EPSILON) return false
  const along = (
    ((point.x - start.x) * (end.x - start.x)) +
    ((point.y - start.y) * (end.y - start.y))
  ) / length
  return along >= -INTERSECTION_EPSILON && along <= length + INTERSECTION_EPSILON
}

function segmentsHaveCoincidentInteriors(firstStart, firstEnd, secondStart, secondEnd) {
  const firstLength = segmentLength(firstStart, firstEnd)
  const secondLength = segmentLength(secondStart, secondEnd)
  if (firstLength <= INTERSECTION_EPSILON || secondLength <= INTERSECTION_EPSILON) return false
  if (
    Math.abs(signedPerpendicularDistance(firstStart, firstEnd, secondStart)) > INTERSECTION_EPSILON ||
    Math.abs(signedPerpendicularDistance(firstStart, firstEnd, secondEnd)) > INTERSECTION_EPSILON ||
    Math.abs(signedPerpendicularDistance(secondStart, secondEnd, firstStart)) > INTERSECTION_EPSILON ||
    Math.abs(signedPerpendicularDistance(secondStart, secondEnd, firstEnd)) > INTERSECTION_EPSILON
  ) return false

  const directionX = (firstEnd.x - firstStart.x) / firstLength
  const directionY = (firstEnd.y - firstStart.y) / firstLength
  const secondStartProjection = (
    ((secondStart.x - firstStart.x) * directionX) +
    ((secondStart.y - firstStart.y) * directionY)
  )
  const secondEndProjection = (
    ((secondEnd.x - firstStart.x) * directionX) +
    ((secondEnd.y - firstStart.y) * directionY)
  )
  const overlap = Math.min(
    firstLength,
    Math.max(secondStartProjection, secondEndProjection),
  ) - Math.max(
    0,
    Math.min(secondStartProjection, secondEndProjection),
  )
  return overlap > INTERSECTION_EPSILON
}

function segmentsProperlyCross(firstStart, firstEnd, secondStart, secondEnd) {
  if (
    segmentLength(firstStart, firstEnd) <= INTERSECTION_EPSILON ||
    segmentLength(secondStart, secondEnd) <= INTERSECTION_EPSILON
  ) return false
  const firstToSecondStart = signedPerpendicularDistance(firstStart, firstEnd, secondStart)
  const firstToSecondEnd = signedPerpendicularDistance(firstStart, firstEnd, secondEnd)
  const secondToFirstStart = signedPerpendicularDistance(secondStart, secondEnd, firstStart)
  const secondToFirstEnd = signedPerpendicularDistance(secondStart, secondEnd, firstEnd)
  return (
    (
      (firstToSecondStart > INTERSECTION_EPSILON && firstToSecondEnd < -INTERSECTION_EPSILON) ||
      (firstToSecondStart < -INTERSECTION_EPSILON && firstToSecondEnd > INTERSECTION_EPSILON)
    ) && (
      (secondToFirstStart > INTERSECTION_EPSILON && secondToFirstEnd < -INTERSECTION_EPSILON) ||
      (secondToFirstStart < -INTERSECTION_EPSILON && secondToFirstEnd > INTERSECTION_EPSILON)
    )
  )
}

function segmentContactPoints(firstStart, firstEnd, secondStart, secondEnd) {
  const candidates = [
    [firstStart, secondStart, secondEnd],
    [firstEnd, secondStart, secondEnd],
    [secondStart, firstStart, firstEnd],
    [secondEnd, firstStart, firstEnd],
  ]
  const contacts = []
  for (const [point, otherStart, otherEnd] of candidates) {
    if (!pointContactsSegment(point, otherStart, otherEnd)) continue
    if (contacts.some((contact) => pointsContact(contact, point))) continue
    contacts.push(point)
  }
  return contacts
}

function routeEndpointIdsAtPoint(route, point) {
  const points = Array.isArray(route?.points) ? route.points : []
  const endpointIds = new Set()
  const sourceId = String(route?.sourceContactId || route?.sourceId || "")
  const targetId = String(route?.targetContactId || route?.targetId || "")
  if (sourceId !== "" && pointsContact(points[0], point)) endpointIds.add(sourceId)
  if (targetId !== "" && pointsContact(points.at(-1), point)) endpointIds.add(targetId)
  for (const junction of route?.junctions || []) {
    const junctionId = String(junction?.id || "")
    if (junctionId !== "" && pointsContact(junction?.point, point)) endpointIds.add(junctionId)
  }
  return endpointIds
}

function genuineSharedRouteEndpointContact(first, second, point) {
  const firstEndpointIds = routeEndpointIdsAtPoint(first, point)
  const secondEndpointIds = routeEndpointIdsAtPoint(second, point)
  return [...firstEndpointIds].some((endpointId) => secondEndpointIds.has(endpointId))
}

function routePairGeometry(first, second) {
  const firstPoints = Array.isArray(first?.points) ? first.points : []
  const secondPoints = Array.isArray(second?.points) ? second.points : []
  if (
    firstPoints.length < 2 ||
    secondPoints.length < 2 ||
    !firstPoints.every((point) => Number.isFinite(point?.x) && Number.isFinite(point?.y)) ||
    !secondPoints.every((point) => Number.isFinite(point?.x) && Number.isFinite(point?.y))
  ) return {coincidentInteriors: false, diagnosticContact: false}

  let coincidentInteriors = false
  let diagnosticContact = false

  for (let firstIndex = 1; firstIndex < firstPoints.length; firstIndex += 1) {
    for (let secondIndex = 1; secondIndex < secondPoints.length; secondIndex += 1) {
      const firstStart = firstPoints[firstIndex - 1]
      const firstEnd = firstPoints[firstIndex]
      const secondStart = secondPoints[secondIndex - 1]
      const secondEnd = secondPoints[secondIndex]
      if (segmentsHaveCoincidentInteriors(firstStart, firstEnd, secondStart, secondEnd)) {
        coincidentInteriors = true
        continue
      }
      if (segmentsProperlyCross(firstStart, firstEnd, secondStart, secondEnd)) {
        diagnosticContact = true
        continue
      }
      const contacts = segmentContactPoints(firstStart, firstEnd, secondStart, secondEnd)
      if (contacts.some((point) => !genuineSharedRouteEndpointContact(first, second, point))) {
        diagnosticContact = true
      }
    }
  }
  return {coincidentInteriors, diagnosticContact}
}

function hasDistinctRoutePoints(points) {
  for (let leftIndex = 0; leftIndex < points.length; leftIndex += 1) {
    for (let rightIndex = leftIndex + 1; rightIndex < points.length; rightIndex += 1) {
      const deltaX = points[rightIndex].x - points[leftIndex].x
      const deltaY = points[rightIndex].y - points[leftIndex].y
      if (Math.hypot(deltaX, deltaY) > INTERSECTION_EPSILON) return true
    }
  }
  return false
}

function pointContactsBoxBoundary(point, box) {
  if (!point || !finiteBox(box)) return false
  const withinX = point.x >= box.minX - INTERSECTION_EPSILON
    && point.x <= box.maxX + INTERSECTION_EPSILON
  const withinY = point.y >= box.minY - INTERSECTION_EPSILON
    && point.y <= box.maxY + INTERSECTION_EPSILON
  if (!withinX || !withinY) return false

  return Math.abs(point.x - box.minX) <= INTERSECTION_EPSILON
    || Math.abs(point.x - box.maxX) <= INTERSECTION_EPSILON
    || Math.abs(point.y - box.minY) <= INTERSECTION_EPSILON
    || Math.abs(point.y - box.maxY) <= INTERSECTION_EPSILON
}

function pointContactsPolyline(point, points) {
  for (let index = 1; index < (points || []).length; index += 1) {
    if (pointContactsSegment(point, points[index - 1], points[index])) return true
  }
  return false
}

export function validateTopologyScene(scene) {
  const errors = []
  let routeCrossingPairs = 0
  const nodes = Array.isArray(scene?.nodes) ? scene.nodes : []
  const groups = Array.isArray(scene?.groups) ? scene.groups : []
  const routes = Array.isArray(scene?.routes) ? scene.routes : []
  const manifolds = Array.isArray(scene?.manifolds) ? scene.manifolds : []
  const physicalRoutes = Array.isArray(scene?.physicalRoutes) ? scene.physicalRoutes : routes
  const nodeById = new Map(nodes.map((node) => [node.id, node]))
  const routeById = new Map(routes.map((route) => [route.id, route]))
  const manifoldById = new Map(manifolds.map((manifold) => [manifold.id, manifold]))
  const nodeBoxes = new Map()

  for (const node of nodes) {
    const values = [node.center?.x, node.center?.y, node.width, node.height]
    if (!values.every(Number.isFinite) || node.width <= 0 || node.height <= 0) {
      errors.push(`node ${node.id} has non-finite geometry`)
      continue
    }
    if (node.geometryContractError) errors.push(node.geometryContractError)
    nodeBoxes.set(node.id, boxForNode(node))
  }

  for (const group of groups) {
    if (!finiteBox(group.bounds)) errors.push(`group ${group.id} has non-finite geometry`)
  }
  if (!finiteBox(scene?.bounds)) errors.push("scene bounds have non-finite geometry")

  for (let leftIndex = 0; leftIndex < nodes.length; leftIndex += 1) {
    for (let rightIndex = leftIndex + 1; rightIndex < nodes.length; rightIndex += 1) {
      const left = nodes[leftIndex]
      const right = nodes[rightIndex]
      const leftBox = nodeBoxes.get(left.id)
      const rightBox = nodeBoxes.get(right.id)
      if (leftBox && rightBox && boxesOverlap(leftBox, rightBox)) {
        errors.push(`non-nested nodes ${left.id} and ${right.id} overlap`)
      }
    }
  }

  for (let leftIndex = 0; leftIndex < groups.length; leftIndex += 1) {
    const left = groups[leftIndex]
    if (!finiteBox(left.bounds)) continue
    for (let rightIndex = leftIndex + 1; rightIndex < groups.length; rightIndex += 1) {
      const right = groups[rightIndex]
      if (finiteBox(right.bounds) && boxesOverlap(left.bounds, right.bounds)) {
        errors.push(`non-nested groups ${left.id} and ${right.id} overlap`)
      }
    }
    for (const node of nodes) {
      const nodeBox = nodeBoxes.get(node.id)
      if (node.groupId !== left.id && nodeBox && boxesOverlap(left.bounds, nodeBox)) {
        errors.push(`non-nested group ${left.id} and node ${node.id} overlap`)
      }
    }

    for (const nodeId of [left.gatewayId, ...(left.memberIds || [])]) {
      const memberBox = nodeBoxes.get(nodeId)
      if (!memberBox || !boxContains(left.bounds, memberBox)) {
        errors.push(`node ${nodeId} is outside group ${left.id}`)
      }
    }
  }

  for (const route of physicalRoutes) {
    if (route.endpointBindingError) {
      errors.push(route.endpointBindingError)
      continue
    }
    if (!Array.isArray(route.points) || route.points.length < 2) {
      errors.push(`route ${route.id} must decode from exactly one continuous section`)
      continue
    }
    if (!route.points.every((point) => Number.isFinite(point?.x) && Number.isFinite(point?.y))) {
      errors.push(`route ${route.id} has non-finite geometry`)
      continue
    }
    if (!hasDistinctRoutePoints(route.points)) {
      errors.push(`route ${route.id} must decode from exactly one continuous section`)
      continue
    }

    const incidentNodeIds = new Set(
      Array.isArray(route.incidentNodeIds)
        ? route.incidentNodeIds
        : [route.sourceId, route.targetId],
    )

    for (const node of nodes) {
      const box = nodeBoxes.get(node.id)
      if (!box) continue
      if (incidentNodeIds.has(node.id) && routeIntersectsBox(route, box, 0)) {
        const role = !route.auxiliary && node.id === route.sourceId
          ? "source "
          : (!route.auxiliary && node.id === route.targetId ? "target " : "")
        errors.push(`route ${route.id} traverses incident ${role}node ${node.id} open interior`)
      } else if (!incidentNodeIds.has(node.id) && routeIntersectsBox(route, box)) {
        errors.push(`route ${route.id} intersects nonincident node ${node.id}`)
      }
    }

    for (const group of groups) {
      const incidentGroupIds = new Set([...incidentNodeIds]
        .map((nodeId) => nodeById.get(nodeId)?.groupId)
        .filter(Boolean))
      if (
        group.id === route.sourceId ||
        group.id === route.targetId ||
        incidentGroupIds.has(group.id)
      ) continue
      if (finiteBox(group.bounds) && routeIntersectsBox(route, group.bounds)) {
        errors.push(`route ${route.id} intersects nonincident group ${group.id}`)
      }
    }
  }

  for (const route of routes) {
    if (!Array.isArray(route.points) || route.points.length < 2) continue
    const sourceBox = nodeBoxes.get(route.sourceId)
    const targetBox = nodeBoxes.get(route.targetId)
    const sourceManifold = route.sourceManifoldId
      ? manifoldById.get(route.sourceManifoldId)
      : null
    const targetManifold = route.targetManifoldId
      ? manifoldById.get(route.targetManifoldId)
      : null
    if (sourceManifold) {
      const branch = sourceManifold.branchContacts.find((candidate) => candidate.routeId === route.id)
      if (!branch || !pointsContact(route.points[0], branch.point)) {
        errors.push(`route ${route.id} does not contact source manifold ${sourceManifold.id}`)
      }
    } else if (!pointContactsBoxBoundary(route.points[0], sourceBox)) {
      errors.push(`route ${route.id} does not contact source endpoint ${route.sourceId} boundary within ${INTERSECTION_EPSILON}`)
    }
    if (targetManifold) {
      const branch = targetManifold.branchContacts.find((candidate) => candidate.routeId === route.id)
      if (!branch || !pointsContact(route.points.at(-1), branch.point)) {
        errors.push(`route ${route.id} does not contact target manifold ${targetManifold.id}`)
      }
    } else if (!pointContactsBoxBoundary(route.points.at(-1), targetBox)) {
      errors.push(`route ${route.id} does not contact target endpoint ${route.targetId} boundary within ${INTERSECTION_EPSILON}`)
    }
  }

  for (const manifold of manifolds) {
    if (manifold.geometryContractError) errors.push(manifold.geometryContractError)
    if (manifold.endpointBindingError) errors.push(manifold.endpointBindingError)
    const nodeBox = nodeBoxes.get(manifold.nodeId)
    if (!pointContactsBoxBoundary(manifold.nodeContact, nodeBox)) {
      errors.push(`manifold ${manifold.id} does not contact node ${manifold.nodeId} boundary`)
    }
    const trunkPoints = Array.isArray(manifold.trunkPoints) ? manifold.trunkPoints : []
    const expectedStart = manifold.endpoint === "source" ? manifold.nodeContact : manifold.trunkContact
    const expectedEnd = manifold.endpoint === "source" ? manifold.trunkContact : manifold.nodeContact
    if (
      trunkPoints.length < 2 ||
      !pointsContact(trunkPoints[0], expectedStart) ||
      !pointsContact(trunkPoints.at(-1), expectedEnd)
    ) {
      errors.push(`manifold ${manifold.id} trunk is disconnected`)
    }
    if (!pointContactsPolyline(manifold.trunkContact, manifold.railPoints)) {
      errors.push(`manifold ${manifold.id} trunk does not contact its rail`)
    }
    for (const branch of manifold.branchContacts || []) {
      const route = routeById.get(branch.routeId)
      const routePoint = manifold.endpoint === "source" ? route?.points?.[0] : route?.points?.at(-1)
      if (!pointContactsPolyline(branch.point, manifold.railPoints)) {
        errors.push(`manifold ${manifold.id} branch ${branch.routeId} does not contact its rail`)
      }
      if (!routePoint || !pointsContact(routePoint, branch.point)) {
        errors.push(`manifold ${manifold.id} branch ${branch.routeId} does not contact its route`)
      }
    }
  }

  for (let leftIndex = 0; leftIndex < physicalRoutes.length; leftIndex += 1) {
    for (let rightIndex = leftIndex + 1; rightIndex < physicalRoutes.length; rightIndex += 1) {
      const left = physicalRoutes[leftIndex]
      const right = physicalRoutes[rightIndex]
      const geometry = routePairGeometry(left, right)
      if (geometry.coincidentInteriors) {
        const [leftId, rightId] = [String(left?.id || ""), String(right?.id || "")]
          .sort((first, second) => first.localeCompare(second))
        errors.push(`routes ${leftId} and ${rightId} have coincident interior segments`)
      }
      if (geometry.diagnosticContact) routeCrossingPairs += 1
    }
  }

  return {ok: errors.length === 0, errors, diagnostics: {routeCrossingPairs}}
}

export async function layoutTopologyScene(
  sceneInput,
  {engine, profile = LANDSCAPE_PROFILE} = {},
) {
  if (!engine || typeof engine.layout !== "function") throw new Error("ELK layout engine is unavailable")
  const elkResult = await engine.layout(buildElkSceneGraph(sceneInput, profile))
  const decoded = decodeElkScene(elkResult, sceneInput)
  const validation = validateTopologyScene(decoded)
  if (!validation.ok) {
    throw new Error(`invalid topology scene: ${validation.errors.join("; ")}`)
  }

  return {
    ...decoded,
    key: `${sceneInput.graphKey}:${profile.key}`,
    graphKey: sceneInput.graphKey,
    profileKey: profile.key,
    manifest: {...sceneInput.manifest},
  }
}

export function applyTopologySceneToGraph(graph, scene) {
  const sceneNodeById = new Map((scene?.nodes || []).map((node) => [node.id, node]))
  const nodes = (graph?.nodes || []).map((node) => {
    const sceneNode = sceneNodeById.get(node.id)
    if (!sceneNode) return node
    return {
      ...node,
      x: sceneNode.center.x,
      y: sceneNode.center.y,
    }
  })

  return {
    ...graph,
    nodes,
    _topologyScene: scene,
    _layoutMode: "elk-scene-detail",
  }
}
