import {DESKTOP_PAYLOAD_VIDEO} from "./media_frame"
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

export function createWebCodecsDesktopVideoRenderTarget({
  context,
  encodedVideoChunkFactory = defaultEncodedVideoChunkFactory(),
  videoDecoderFactory = defaultVideoDecoderFactory(),
} = {}) {
  if (!context || typeof context.drawImage !== "function" || !encodedVideoChunkFactory || !videoDecoderFactory) {
    return null
  }

  let decoder = null
  let decoderCodec = ""

  const closeDecoder = () => {
    decoder?.close?.()
    decoder = null
    decoderCodec = ""
  }

  const configureDecoder = (codec) => {
    if (!codec) {
      return false
    }

    if (decoder && decoderCodec === codec) {
      return true
    }

    closeDecoder()
    decoder = videoDecoderFactory({
      output(frame) {
        try {
          context.drawImage(frame, 0, 0, context.canvas?.width || frame.displayWidth, context.canvas?.height || frame.displayHeight)
        } finally {
          frame.close?.()
        }
      },
      error() {},
    })
    decoder.configure({
      codec,
      hardwareAcceleration: "prefer-hardware",
      optimizeForLatency: true,
    })
    decoderCodec = codec

    return true
  }

  return {
    canvas: context.canvas || null,
    kind: "webcodecs",
    resizeForFrame(frame) {
      return resizeCanvasForFrame(context.canvas, frame)
    },
    applyFrame(frame) {
      if (frame?.payloadFamily !== DESKTOP_PAYLOAD_VIDEO || !frame.payload || frame.payload.byteLength === 0) {
        return 0
      }

      if (!configureDecoder(normalizeCodec(frame.encoding))) {
        return 0
      }

      decoder.decode(encodedVideoChunkFactory({
        type: frame.keyframe || frame.fullFrame ? "key" : "delta",
        timestamp: videoTimestampMicroseconds(frame),
        data: frame.payload,
      }))

      return 1
    },
    close: closeDecoder,
  }
}

export function createBrowserDesktopRenderTarget(canvas, {
  createImageData,
  encodedVideoChunkFactory,
  videoDecoderFactory,
} = {}) {
  const context = canvas?.getContext?.("2d", {alpha: false})
  const canvasTarget = createCanvasDesktopRenderTarget(context, {createImageData})
  const videoTarget = createWebCodecsDesktopVideoRenderTarget({
    context,
    encodedVideoChunkFactory,
    videoDecoderFactory,
  })

  return {
    canvas,
    kind: videoTarget ? "browser_canvas_webcodecs" : "browser_canvas",
    resizeForFrame(frame) {
      return canvasTarget.resizeForFrame(frame)
    },
    applyFrame(frame) {
      if (frame?.payloadFamily === DESKTOP_PAYLOAD_VIDEO && videoTarget) {
        return videoTarget.applyFrame(frame)
      }

      return canvasTarget.applyFrame(frame)
    },
    close() {
      videoTarget?.close?.()
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

function defaultVideoDecoderFactory(globalRef = globalThis) {
  if (typeof globalRef?.VideoDecoder !== "function") {
    return null
  }

  return (options) => new globalRef.VideoDecoder(options)
}

function defaultEncodedVideoChunkFactory(globalRef = globalThis) {
  if (typeof globalRef?.EncodedVideoChunk !== "function") {
    return null
  }

  return (options) => new globalRef.EncodedVideoChunk(options)
}

function normalizeCodec(codec) {
  return typeof codec === "string" ? codec.trim() : ""
}

function videoTimestampMicroseconds(frame) {
  if (Number.isInteger(frame?.timestampUnixNano) && frame.timestampUnixNano > 0) {
    return Math.floor(frame.timestampUnixNano / 1000)
  }

  return Number.isInteger(frame?.sequence) && frame.sequence > 0 ? frame.sequence * 1000 : 0
}
