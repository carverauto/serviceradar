export function clampZoom(viewState, zoom) {
  const minZoom = Number.isFinite(Number(viewState?.minZoom)) ? Number(viewState.minZoom) : -2
  const maxZoom = Number.isFinite(Number(viewState?.maxZoom)) ? Number(viewState.maxZoom) : 5
  return Math.max(minZoom, Math.min(maxZoom, Number(zoom) || 0))
}

export function deckScale(zoom) {
  return Math.max(0.0001, 2 ** (Number(zoom) || 0))
}

export function canvasPoint(event, canvas) {
  const rect = canvas?.getBoundingClientRect?.()
  if (!rect || rect.width <= 0 || rect.height <= 0) return null

  const x = Math.max(0, Math.min(rect.width, Number(event?.clientX || 0) - rect.left))
  const y = Math.max(0, Math.min(rect.height, Number(event?.clientY || 0) - rect.top))

  return {x, y, width: rect.width, height: rect.height}
}

export function focalZoomViewState(viewState, point, nextZoom) {
  const zoom = Number(viewState?.zoom || 0)
  const clampedZoom = clampZoom(viewState, nextZoom)
  const [targetX = 0, targetY = 0, targetZ = 0] = Array.isArray(viewState?.target) ? viewState.target : [0, 0, 0]

  if (!point || clampedZoom === zoom) {
    return {...viewState, zoom: clampedZoom, target: [targetX, targetY, targetZ]}
  }

  const offsetX = point.x - point.width / 2
  const offsetY = point.y - point.height / 2
  const oldScale = deckScale(zoom)
  const newScale = deckScale(clampedZoom)
  const focalWorldX = targetX + offsetX / oldScale
  const focalWorldY = targetY + offsetY / oldScale

  return {
    ...viewState,
    target: [
      focalWorldX - offsetX / newScale,
      focalWorldY - offsetY / newScale,
      targetZ,
    ],
    zoom: clampedZoom,
  }
}

export function panViewState(viewState, deltaX, deltaY) {
  const [targetX = 0, targetY = 0, targetZ = 0] = Array.isArray(viewState?.target) ? viewState.target : [0, 0, 0]
  const scale = deckScale(viewState?.zoom)

  return {
    ...viewState,
    target: [targetX - deltaX / scale, targetY - deltaY / scale, targetZ],
  }
}

export function wheelZoomDelta(event) {
  const delta = Number(event?.deltaY || 0)
  const direction = delta > 0 ? -1 : 1
  const magnitude = Math.min(3, Math.max(1, Math.abs(delta) / 100))
  return direction * 0.22 * magnitude
}
