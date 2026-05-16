import {describe, expect, it} from "vitest"

import {DESKTOP_PAYLOAD_METADATA, DESKTOP_PAYLOAD_TILE, encodeDesktopMediaFrame, parseDesktopMediaFrame} from "./media_frame"
import {createDesktopRenderQueue} from "./renderer_state"
import {drainDesktopRenderQueue} from "./renderer_runtime"

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
})
