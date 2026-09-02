const MANAGED_CAMERA_STATE_KEYS = [
  "hasAutoFit",
  "hoveredEdgeKey",
  "isProgrammaticViewUpdate",
  "lastDetailsHtml",
  "lastGraph",
  "lastGraphLayerFrame",
  "lastLayoutKey",
  "lastVisibleEdgeCount",
  "lastVisibleNodeCount",
  "layoutMode",
  "layoutRevision",
  "managedTopologyDensityConstraintsCache",
  "managedTopologyDensityConstraintsLayoutCache",
  "managedTopologySceneForMinZoom",
  "managedTopologySceneMinZoom",
  "managedTopologySceneMinZoomKey",
  "managedTopologyVisualDensity",
  "packetFlowCache",
  "packetFlowCacheStamp",
  "pendingClusterFocus",
  "pendingViewportProfileKey",
  "selectedEdgeKey",
  "selectedNodeIndex",
  "topologyLabelDetailsFallbackIds",
  "topologyRouteDiagnostics",
  "userCameraLocked",
  "viewState",
  "viewportProfileKey",
  "wasmReady",
  "zoomMode",
  "zoomTier",
]

function captureManagedCameraState(state) {
  const deckProps = state?.deck?.props
  const hasDeckLayers = Boolean(
    deckProps && Object.prototype.hasOwnProperty.call(deckProps, "layers"),
  )
  return {
    values: Object.fromEntries(MANAGED_CAMERA_STATE_KEYS.map((key) => [key, state?.[key]])),
    layers: state?.layers
      ? {reference: state.layers, values: {...state.layers}}
      : {reference: state?.layers, values: null},
    traversalMaskBuffer: state?.traversalMaskBuffer,
    traversalMaskContents: state?.traversalMaskBuffer?.slice?.(),
    visibilityMaskBuffer: state?.visibilityMaskBuffer,
    visibilityMaskContents: state?.visibilityMaskBuffer?.slice?.(),
    hasDeckLayers,
    deckLayers: hasDeckLayers ? deckProps.layers : undefined,
  }
}

function restoreObjectSnapshot(state, key, snapshot) {
  if (!snapshot?.reference || !snapshot.values) {
    state[key] = snapshot?.reference
    return
  }
  for (const existingKey of Object.keys(snapshot.reference)) {
    if (!Object.prototype.hasOwnProperty.call(snapshot.values, existingKey)) {
      delete snapshot.reference[existingKey]
    }
  }
  Object.assign(snapshot.reference, snapshot.values)
  state[key] = snapshot.reference
}

function restoreManagedCameraState(context, accepted) {
  const {state} = context
  const changedViewState = state.viewState !== accepted.values.viewState
  const changedDeckLayers = accepted.hasDeckLayers && state.deck?.props?.layers !== accepted.deckLayers
  Object.assign(state, accepted.values)
  restoreObjectSnapshot(state, "layers", accepted.layers)
  if (accepted.traversalMaskBuffer && accepted.traversalMaskContents) {
    accepted.traversalMaskBuffer.set(accepted.traversalMaskContents)
  }
  if (accepted.visibilityMaskBuffer && accepted.visibilityMaskContents) {
    accepted.visibilityMaskBuffer.set(accepted.visibilityMaskContents)
  }
  state.traversalMaskBuffer = accepted.traversalMaskBuffer
  state.visibilityMaskBuffer = accepted.visibilityMaskBuffer

  if ((!changedViewState || !accepted.values.viewState) && !changedDeckLayers) return
  const deckProps = {}
  if (changedViewState && accepted.values.viewState) deckProps.viewState = accepted.values.viewState
  if (changedDeckLayers) deckProps.layers = accepted.deckLayers
  try {
    state.deck?.setProps?.(deckProps)
  } catch (_restoreError) {
    // The accepted state remains authoritative even if Deck cannot redraw it.
  }
  Object.assign(state, accepted.values)
  restoreObjectSnapshot(state, "layers", accepted.layers)
}

function ownedManagedErrorSummaryAtStart(state, acceptedSummary) {
  if (state.managedTopologyCameraErrorActive !== true) return false
  const ownedSummary = state.managedTopologyCameraErrorSummary
  if (typeof ownedSummary === "string") return acceptedSummary === ownedSummary
  return acceptedSummary === "topology render unavailable"
    || acceptedSummary === "topology layout unavailable"
    || acceptedSummary?.startsWith?.("layout resize failed:") === true
}

function surfaceManagedCameraError(
  state,
  error,
  acceptedSummary,
  ownedSummaryAtStart,
  {errorReason, errorSummary},
) {
  if (!ownedSummaryAtStart) {
    state.managedTopologyCameraErrorPreviousSummary = acceptedSummary
  }
  state.managedTopologyCameraErrorActive = true
  state.managedTopologyCameraErrorSummary = errorSummary
  if (state.summary) state.summary.textContent = errorSummary
  if (!ownedSummaryAtStart) {
    state.pushEvent?.("god_view_stream_error", {reason: errorReason, message: `${error}`})
  }
}

function clearManagedCameraError(state) {
  if (state.managedTopologyCameraErrorActive !== true) return
  const ownedSummary = state.managedTopologyCameraErrorSummary || "topology render unavailable"
  if (state.summary?.textContent === ownedSummary) {
    state.summary.textContent = typeof state.managedTopologyCameraErrorPreviousSummary === "string"
      ? state.managedTopologyCameraErrorPreviousSummary
      : ""
  }
  state.managedTopologyCameraErrorActive = false
  state.managedTopologyCameraErrorPreviousSummary = null
  state.managedTopologyCameraErrorSummary = null
}

export function surfaceRecoverableManagedTopologyError(
  context,
  error,
  {
    errorReason = "render_error",
    errorSummary = "topology render unavailable",
  } = {},
) {
  const state = context.state
  const acceptedSummary = state.summary?.textContent ?? null
  const ownedSummaryAtStart = ownedManagedErrorSummaryAtStart(state, acceptedSummary)
  surfaceManagedCameraError(
    state,
    error,
    acceptedSummary,
    ownedSummaryAtStart,
    {errorReason, errorSummary},
  )
}

export function runRecoverableManagedCameraUpdate(
  context,
  update,
  {
    clearErrorOnSuccess = true,
    errorReason = "render_error",
    errorSummary = "topology render unavailable",
  } = {},
) {
  const state = context.state
  const accepted = captureManagedCameraState(state)
  const acceptedSummary = state.summary?.textContent ?? null
  const ownedSummaryAtStart = ownedManagedErrorSummaryAtStart(state, acceptedSummary)
  try {
    const value = update()
    if (clearErrorOnSuccess) clearManagedCameraError(state)
    return {ok: true, value}
  } catch (error) {
    restoreManagedCameraState(context, accepted)
    surfaceManagedCameraError(
      state,
      error,
      acceptedSummary,
      ownedSummaryAtStart,
      {errorReason, errorSummary},
    )
    return {ok: false, error}
  }
}
