import {applyCanvasTileFrame, applyWebGPUTileFrame} from "./renderer_state"

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
  gpuQueue = null,
  maxFrames = DEFAULT_MAX_DRAIN_FRAMES,
  renderTarget = null,
  texture = null,
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
    resized = resizeRenderTargetForFrame(renderTarget, context, frame) || resized
    uploads += applyDesktopFrame(frame, renderTarget, context, createImageData, gpuQueue, texture)
  }

  return {frames, uploads, lastSequence, resized}
}

function resizeRenderTargetForFrame(renderTarget, context, frame) {
  if (renderTarget && typeof renderTarget.resizeForFrame === "function") {
    return renderTarget.resizeForFrame(frame)
  }

  return resizeCanvasForFrame(context?.canvas, frame)
}

function applyDesktopFrame(frame, renderTarget, context, createImageData, gpuQueue, texture) {
  if (renderTarget && typeof renderTarget.applyFrame === "function") {
    return renderTarget.applyFrame(frame)
  }

  if (gpuQueue && texture) {
    return applyWebGPUTileFrame(frame, gpuQueue, texture)
  }

  return applyCanvasTileFrame(frame, context, createImageData)
}

export function createCanvasDesktopRenderTarget(context, {
  createImageData,
} = {}) {
  return {
    canvas: context?.canvas || null,
    kind: "canvas2d",
    resizeForFrame(frame) {
      return resizeCanvasForFrame(context?.canvas, frame)
    },
    applyFrame(frame) {
      return applyCanvasTileFrame(frame, context, createImageData)
    },
  }
}

export function createWebGPUDesktopTileRenderTarget({
  gpuQueue,
  texture,
} = {}) {
  if (!gpuQueue || !texture) {
    return null
  }

  return {
    kind: "webgpu",
    applyFrame(frame) {
      return applyWebGPUTileFrame(frame, gpuQueue, texture)
    },
  }
}
