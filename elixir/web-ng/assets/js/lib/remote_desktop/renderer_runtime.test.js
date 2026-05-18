import {describe, expect, it, vi} from "vitest"

import {
  DESKTOP_PAYLOAD_METADATA,
  DESKTOP_PAYLOAD_TILE,
  DESKTOP_PAYLOAD_VIDEO,
  encodeDesktopMediaFrame,
  parseDesktopMediaFrame,
} from "./media_frame"
import {createDesktopRenderQueue} from "./renderer_state"
import {
  createBrowserDesktopRenderTarget,
  createCanvasDesktopRenderTarget,
  createWebCodecsDesktopVideoRenderTarget,
  createWebGPUDesktopTileRenderTarget,
  drainDesktopRenderQueue,
  normalizeDesktopVideoCodec,
} from "./renderer_runtime"

function tileFrame({sequence = 1, width = 8, height = 8} = {}) {
  return parseDesktopMediaFrame(
    encodeDesktopMediaFrame({
      sequence,
      width,
      height,
      payloadFamily: DESKTOP_PAYLOAD_TILE,
      encoding: "rgba",
      metadata: {
        tiles: [{x: 2, y: 3, width: 1, height: 1, payloadOffset: 0, payloadLength: 4}],
      },
      payload: new Uint8Array([1, 2, 3, 255]),
    })
  )
}

function videoFrame({sequence = 1, keyframe = true, width = 8, height = 8, encoding = "avc1.42E01E"} = {}) {
  return parseDesktopMediaFrame(
    encodeDesktopMediaFrame({
      sequence,
      timestampUnixNano: 123_456_789,
      width,
      height,
      payloadFamily: DESKTOP_PAYLOAD_VIDEO,
      encoding,
      keyframe,
      payload: new Uint8Array([1, 2, 3, 4]),
    })
  )
}

describe("remote desktop renderer runtime", () => {
  it("drains queued tile frames into a canvas-compatible surface", () => {
    const queue = createDesktopRenderQueue({maxFrames: 4})
    const putImageDataCalls = []
    const context = {
      canvas: {width: 0, height: 0},
      putImageData(imageData, x, y) {
        putImageDataCalls.push({imageData, x, y})
      },
    }

    queue.push(tileFrame({sequence: 9, width: 16, height: 10}))

    const result = drainDesktopRenderQueue(queue, {
      context,
      createImageData: (bytes, width, height) => ({bytes, width, height}),
    })

    expect(result).toEqual({frames: 1, uploads: 1, lastSequence: 9, resized: true})
    expect(context.canvas).toEqual({width: 16, height: 10})
    expect(putImageDataCalls).toEqual([
      {
        imageData: {bytes: new Uint8Array([1, 2, 3, 255]), width: 1, height: 1},
        x: 2,
        y: 3,
      },
    ])
    expect(queue.length).toBe(0)
  })

  it("honors the per-tick drain budget and leaves remaining frames queued", () => {
    const queue = createDesktopRenderQueue({maxFrames: 4})
    const context = {
      canvas: {width: 8, height: 8},
      putImageData() {},
    }

    queue.push(tileFrame({sequence: 1}))
    queue.push(tileFrame({sequence: 2}))
    queue.push(tileFrame({sequence: 3}))

    const result = drainDesktopRenderQueue(queue, {
      context,
      maxFrames: 2,
      createImageData: (bytes, width, height) => ({bytes, width, height}),
    })

    expect(result.frames).toBe(2)
    expect(result.uploads).toBe(2)
    expect(result.lastSequence).toBe(2)
    expect(queue.length).toBe(1)
  })

  it("prefers WebGPU tile uploads without copying payload bytes", () => {
    const queue = createDesktopRenderQueue({maxFrames: 4})
    const texture = {label: "desktop-texture"}
    const writeTextureCalls = []
    const gpuQueue = {
      writeTexture(destination, source, layout, size) {
        writeTextureCalls.push({destination, source, layout, size})
      },
    }
    const context = {
      canvas: {width: 0, height: 0},
      putImageData() {
        throw new Error("WebGPU path must not use Canvas2D uploads")
      },
    }

    const frame = tileFrame({sequence: 7, width: 32, height: 24})
    queue.push(frame)

    const result = drainDesktopRenderQueue(queue, {
      context,
      gpuQueue,
      texture,
    })

    expect(result).toEqual({frames: 1, uploads: 1, lastSequence: 7, resized: true})
    expect(writeTextureCalls).toHaveLength(1)
    expect(writeTextureCalls[0]).toEqual({
      destination: {
        texture,
        origin: {x: 2, y: 3, z: 0},
      },
      source: new Uint8Array([1, 2, 3, 255]),
      layout: {
        bytesPerRow: 4,
        rowsPerImage: 1,
      },
      size: {
        width: 1,
        height: 1,
        depthOrArrayLayers: 1,
      },
    })
    expect(writeTextureCalls[0].source.buffer).toBe(frame.payload.buffer)
  })

  it("uses renderer targets as the single hot-path frame application boundary", () => {
    const queue = createDesktopRenderQueue({maxFrames: 4})
    const appliedSequences = []
    const renderTarget = {
      applyFrame(frame) {
        appliedSequences.push(frame.sequence)
        return 2
      },
    }

    queue.push(tileFrame({sequence: 21}))
    queue.push(tileFrame({sequence: 22}))

    expect(drainDesktopRenderQueue(queue, {renderTarget, maxFrames: 2})).toEqual({
      frames: 2,
      uploads: 4,
      lastSequence: 22,
      resized: false,
    })
    expect(appliedSequences).toEqual([21, 22])
  })

  it("resizes cached canvas renderer targets without a per-frame context lookup", () => {
    const queue = createDesktopRenderQueue({maxFrames: 4})
    const canvas = {width: 0, height: 0}
    const canvasTarget = createCanvasDesktopRenderTarget({
      canvas,
      putImageData() {},
    }, {
      createImageData: (bytes, width, height) => ({bytes, width, height}),
    })

    queue.push(tileFrame({sequence: 27, width: 640, height: 480}))

    expect(drainDesktopRenderQueue(queue, {renderTarget: canvasTarget})).toEqual({
      frames: 1,
      uploads: 1,
      lastSequence: 27,
      resized: true,
    })
    expect(canvas).toEqual({width: 640, height: 480})
  })

  it("creates canvas and WebGPU renderer target adapters", () => {
    const frame = tileFrame({sequence: 31})
    const canvasCalls = []
    const canvasTarget = createCanvasDesktopRenderTarget({
      putImageData(imageData, x, y) {
        canvasCalls.push({imageData, x, y})
      },
    }, {
      createImageData: (bytes, width, height) => ({bytes, width, height}),
    })
    const texture = {label: "desktop-texture"}
    const webGPUCalls = []
    const webGPUTarget = createWebGPUDesktopTileRenderTarget({
      texture,
      gpuQueue: {
        writeTexture(destination, source, layout, size) {
          webGPUCalls.push({destination, source, layout, size})
        },
      },
    })

    expect(canvasTarget.kind).toBe("canvas2d")
    expect(canvasTarget.applyFrame(frame)).toBe(1)
    expect(canvasCalls[0].imageData.bytes.buffer).toBe(frame.payload.buffer)

    expect(webGPUTarget.kind).toBe("webgpu")
    expect(webGPUTarget.applyFrame(frame)).toBe(1)
    expect(webGPUCalls[0].destination.texture).toBe(texture)
    expect(webGPUCalls[0].source.buffer).toBe(frame.payload.buffer)
    expect(createWebGPUDesktopTileRenderTarget()).toBeNull()
  })

  it("decodes browser video frames through WebCodecs without copying payload bytes", () => {
    const decoderCalls = []
    const chunks = []
    const closedFrames = []
    const drawImageCalls = []
    const context = {
      canvas: {width: 0, height: 0},
      drawImage(frame, x, y, width, height) {
        drawImageCalls.push({frame, x, y, width, height})
      },
    }
    const target = createWebCodecsDesktopVideoRenderTarget({
      context,
      encodedVideoChunkFactory(options) {
        chunks.push(options)
        return {chunk: options}
      },
      videoDecoderFactory(options) {
        decoderCalls.push(options)
        return {
          configure(config) {
            decoderCalls.push({config})
          },
          decode(chunk) {
            options.output({
              chunk,
              displayWidth: 1024,
              displayHeight: 768,
              close() {
                closedFrames.push(chunk)
              },
            })
          },
          close() {
            decoderCalls.push({closed: true})
          },
        }
      },
    })
    const frame = videoFrame({sequence: 41, width: 1024, height: 768})

    expect(target.kind).toBe("webcodecs")
    expect(target.resizeForFrame(frame)).toBe(true)
    expect(target.applyFrame(frame)).toBe(1)
    expect(chunks).toEqual([
      {
        type: "key",
        timestamp: 123_456,
        data: frame.payload,
      },
    ])
    expect(chunks[0].data.buffer).toBe(frame.payload.buffer)
    expect(drawImageCalls).toHaveLength(1)
    expect(drawImageCalls[0]).toMatchObject({x: 0, y: 0, width: 1024, height: 768})
    expect(closedFrames).toHaveLength(1)

    target.close()
    expect(decoderCalls).toContainEqual({closed: true})
  })

  it("strictly allowlists WebCodecs video codec strings", () => {
    expect(normalizeDesktopVideoCodec("avc1.42E01E")).toBe("avc1.42e01e")
    expect(normalizeDesktopVideoCodec("vp8")).toBe("vp8")
    expect(normalizeDesktopVideoCodec("vp09.00.10.08")).toBe("vp09.00.10.08")
    expect(normalizeDesktopVideoCodec("av01.0.08M.08")).toBe("av01.0.08m.08")
    expect(normalizeDesktopVideoCodec("h264")).toBe("")
    expect(normalizeDesktopVideoCodec("avc1; x-invalid")).toBe("")
  })

  it("rejects disallowed WebCodecs video codec strings", () => {
    const target = createWebCodecsDesktopVideoRenderTarget({
      context: {
        canvas: {width: 8, height: 8},
        drawImage() {},
      },
      encodedVideoChunkFactory: (options) => options,
      videoDecoderFactory: () => ({
        configure() {
          throw new Error("decoder must not configure disallowed codecs")
        },
        decode() {},
        close() {},
      }),
    })

    expect(() =>
      target.applyFrame(videoFrame({sequence: 44, width: 8, height: 8, encoding: "h264; bad=1"}))
    ).toThrow(/codec/)
  })

  it("rejects decoded video frames that do not match the render target dimensions", () => {
    const closedFrames = []
    const target = createWebCodecsDesktopVideoRenderTarget({
      context: {
        canvas: {width: 8, height: 8},
        drawImage() {
          throw new Error("dimension mismatch must not draw")
        },
      },
      encodedVideoChunkFactory: (options) => options,
      videoDecoderFactory: (options) => ({
        configure() {},
        decode(chunk) {
          options.output({
            chunk,
            displayWidth: 16,
            displayHeight: 8,
            close() {
              closedFrames.push(chunk)
            },
          })
        },
        close() {},
      }),
    })

    expect(() => target.applyFrame(videoFrame({sequence: 45, width: 8, height: 8}))).toThrow(/dimensions/)
    expect(closedFrames).toHaveLength(1)
  })

  it("routes browser targets between WebCodecs video and canvas tile frames", () => {
    const queue = createDesktopRenderQueue({maxFrames: 4})
    const decodedChunks = []
    const putImageDataCalls = []
    const canvas = {
      width: 0,
      height: 0,
      getContext() {
        return {
          canvas,
          drawImage() {},
          putImageData(imageData, x, y) {
            putImageDataCalls.push({imageData, x, y})
          },
        }
      },
    }
    const target = createBrowserDesktopRenderTarget(canvas, {
      createImageData: (bytes, width, height) => ({bytes, width, height}),
      encodedVideoChunkFactory: (options) => options,
      videoDecoderFactory: (options) => ({
        configure() {},
        decode(chunk) {
          decodedChunks.push(chunk)
          options.output({displayWidth: 1280, displayHeight: 720, close() {}})
        },
        close() {},
      }),
    })

    queue.push(videoFrame({sequence: 51, width: 1280, height: 720}))
    queue.push(tileFrame({sequence: 52, width: 1280, height: 720}))

    expect(drainDesktopRenderQueue(queue, {renderTarget: target, maxFrames: 2})).toEqual({
      frames: 2,
      uploads: 2,
      lastSequence: 52,
      resized: true,
    })
    expect(decodedChunks).toHaveLength(1)
    expect(putImageDataCalls).toHaveLength(1)
    expect(target.kind).toBe("browser_canvas_webcodecs")
  })

  it("counts metadata frames without treating them as screen-pixel uploads", () => {
    const queue = createDesktopRenderQueue({maxFrames: 2})
    const context = {
      canvas: {width: 8, height: 8},
      putImageData() {
        throw new Error("metadata must not reach the canvas upload path")
      },
    }

    queue.push(parseDesktopMediaFrame(
      encodeDesktopMediaFrame({
        sequence: 12,
        payloadFamily: DESKTOP_PAYLOAD_METADATA,
        metadata: {role: "stats"},
      })
    ))

    expect(drainDesktopRenderQueue(queue, {context})).toEqual({
      frames: 1,
      uploads: 0,
      lastSequence: 12,
      resized: false,
    })
  })

  it("drops renderer failures without breaking later frame drains", () => {
    const queue = createDesktopRenderQueue({maxFrames: 4})
    const putImageDataCalls = []
    const onFrameError = vi.fn()
    const context = {
      canvas: {width: 8, height: 8},
      putImageData(imageData, x, y) {
        putImageDataCalls.push({imageData, x, y})
      },
    }

    queue.push(parseDesktopMediaFrame(
      encodeDesktopMediaFrame({
        sequence: 61,
        width: 8,
        height: 8,
        payloadFamily: DESKTOP_PAYLOAD_TILE,
        encoding: "rgba",
        metadata: new Uint8Array([0x7b]),
        payload: new Uint8Array([1, 2, 3, 255]),
      })
    ))
    queue.push(tileFrame({sequence: 62, width: 8, height: 8}))

    const result = drainDesktopRenderQueue(queue, {
      context,
      createImageData: (bytes, width, height) => ({bytes, width, height}),
      maxFrames: 2,
      onFrameError,
    })

    expect(result).toMatchObject({
      frames: 2,
      uploads: 1,
      lastSequence: 62,
      resized: false,
      errors: 1,
    })
    expect(result.lastError).toBeInstanceOf(SyntaxError)
    expect(onFrameError).toHaveBeenCalledWith(result.lastError, expect.objectContaining({sequence: 61}))
    expect(putImageDataCalls).toHaveLength(1)
    expect(queue.length).toBe(0)
  })
})
