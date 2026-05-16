import {applyCanvasTileFrame} from "./renderer_state"

const DEFAULT_MAX_DRAIN_FRAMES = 4

function positiveInteger(value, fallback = 0) {
  return Number.isInteger(value) && value > 0 ? value : fallback
}

function resizeCanvasForFrame(canvas, frame) {
  const width = positiveInteger(frame?.width)
  const height = positiveInteger(frame?.height)

  if (!canvas || width === 0 || height === 0) {
    return false
  }

  const resized = canvas.width !== width || canvas.height !== height
  if (resized) {
    canvas.width = width
    canvas.height = height
  }

  return resized
}

export function drainDesktopRenderQueue(queue, {
  context = null,
  createImageData,
  maxFrames = DEFAULT_MAX_DRAIN_FRAMES,
} = {}) {
  if (!queue || typeof queue.shift !== "function") {
    return {frames: 0, uploads: 0, lastSequence: null, resized: false}
  }

  const safeMaxFrames = positiveInteger(maxFrames, DEFAULT_MAX_DRAIN_FRAMES)
  let frames = 0
  let uploads = 0
  let lastSequence = null
  let resized = false

  for (let index = 0; index < safeMaxFrames; index += 1) {
    const frame = queue.shift()

    if (!frame) {
      break
    }

    frames += 1
    lastSequence = frame.sequence ?? lastSequence
    resized = resizeCanvasForFrame(context?.canvas, frame) || resized
    uploads += applyCanvasTileFrame(frame, context, createImageData)
  }

  return {frames, uploads, lastSequence, resized}
}
