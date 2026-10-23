import {expect, test} from "@playwright/test"
import {readFile} from "node:fs/promises"
import {createServer} from "node:http"
import {resolve} from "node:path"

let server, origin, fixture, media, init
const requests = []

test.beforeAll(async () => {
  const path = resolve(process.env.TEST_SRCDIR, process.env.TEST_WORKSPACE, process.env.CAMERA_BROWSER_FIXTURE)
  fixture = JSON.parse(await readFile(path, "utf8"))
  console.info(JSON.stringify({syntheticCodecs: fixture.codecs}))
  init = Buffer.from(fixture.init, "base64")
  media = Buffer.concat(fixture.fragments.map(fragment => Buffer.from(fragment.base64, "base64")))
  expect(media.length).toBe(fixture.high_water)
  expect(fixture.fragments).toHaveLength(3)
  expect(fixture.fragments.map(fragment => fragment.start_ns)).toEqual([0, 2e9, 4e9])
  expect(fixture.fragments.map(fragment => fragment.duration_ns)).toEqual([2e9, 2e9, 2e9])

  server = createServer((req, res) => {
    if (req.url === "/") {
      res.writeHead(200, {"Content-Type": "text/html"})
      res.end('<!doctype html><title>Synthetic recorded media proof</title><video muted></video><canvas width="64" height="64"></canvas>')
    } else if (req.url === "/init" || req.url === "/invalid-init") {
      const bytes = Buffer.from(init)
      // A box shorter than its own header is invalid ISO BMFF. Chromium must
      // reject this through the same append path that accepted the real init.
      if (req.url === "/invalid-init") bytes.writeUInt32BE(4, 0)
      res.writeHead(200, {"Content-Type": "video/mp4", "Content-Length": bytes.length})
      res.end(bytes)
    } else if (req.url === "/media" || req.url === "/invalid-range") {
      const match = /^bytes=(\d+)-(\d+)$/.exec(req.headers.range || "")
      const entry = match && fixture.fragments.find(fragment =>
        fragment.offset === Number(match[1]) && fragment.offset + fragment.length - 1 === Number(match[2]))
      if (!entry) {
        res.writeHead(416, {"Content-Range": `bytes */${media.length}`})
        res.end()
        return
      }
      requests.push(entry.sequence)
      const end = entry.offset + entry.length
      res.writeHead(206, {
        "Content-Type": "video/mp4",
        "Content-Length": entry.length,
        "Content-Range": `bytes ${entry.offset + (req.url === "/invalid-range" ? 1 : 0)}-${end - 1}/${media.length}`,
      })
      res.end(media.subarray(entry.offset, end))
    } else {
      res.writeHead(404)
      res.end()
    }
  })
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve))
  origin = `http://127.0.0.1:${server.address().port}`
})

test.afterAll(async () => {
  if (server) await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()))
})

async function openRecording(page, initPath = "/init", mediaPath = "/media") {
  await page.goto(origin)
  return page.evaluate(async ({codecs, initPath, mediaPath, fragments, highWater}) => {
    const video = document.querySelector("video")
    const source = new MediaSource()
    const opened = new Promise(resolve => source.addEventListener("sourceopen", resolve, {once: true}))
    video.src = URL.createObjectURL(source)
    await opened
    const {profile, compatibility, level} = codecs.avc1
    const codec = `avc1.${[profile, compatibility, level].map(byte => byte.toString(16).padStart(2, "0")).join("")}`
    const buffer = source.addSourceBuffer(`video/mp4; codecs="${codec}"`)

    const update = operation => new Promise((resolve, reject) => {
      const done = error => {
        clearTimeout(timer)
        buffer.removeEventListener("updateend", finished)
        buffer.removeEventListener("error", failed)
        error ? reject(error) : resolve()
      }
      const finished = () => done()
      const failed = () => done(new Error("source-buffer-error"))
      const timer = setTimeout(() => done(new Error("source-buffer-timeout")), 5_000)
      buffer.addEventListener("updateend", finished)
      buffer.addEventListener("error", failed)
      try { operation() } catch (error) { done(error) }
    })

    const initial = await fetch(initPath)
    if (!initial.ok) throw new Error(`init HTTP ${initial.status}`)
    const initialBytes = await initial.arrayBuffer()
    try {
      await update(() => buffer.appendBuffer(new Uint8Array(initialBytes)))
    } catch (error) {
      return {error: error.message}
    }

    source.duration = 6
    window.seekRecordedFrame = async (sequence, time) => {
      const entry = fragments.find(fragment => fragment.sequence === sequence)
      const end = entry.offset + entry.length - 1
      const response = await fetch(mediaPath, {headers: {Range: `bytes=${entry.offset}-${end}`}})
      if (response.status !== 206 || response.headers.get("Content-Range") !== `bytes ${entry.offset}-${end}/${highWater}`) {
        throw new Error("invalid-fragment-range")
      }
      const bytes = await response.arrayBuffer()
      if (bytes.byteLength !== entry.length) throw new Error("incomplete-fragment-range")

      // Drop prior bytes so each seek must decode the selected committed GOP.
      if (buffer.buffered.length) await update(() => buffer.remove(0, source.duration))
      if (buffer.buffered.length) throw new Error("fragment-eviction-incomplete")
      await update(() => buffer.appendBuffer(bytes))
      const decoded = new Promise((resolve, reject) => {
        let callback
        const timer = setTimeout(() => {
          video.cancelVideoFrameCallback(callback)
          reject(new Error("decoded-frame-timeout"))
        }, 5_000)
        const presented = (_now, metadata) => {
          if (Math.abs(metadata.mediaTime - time) > 1 / 15) {
            callback = video.requestVideoFrameCallback(presented)
            return
          }
          clearTimeout(timer)
          const canvas = document.querySelector("canvas")
          const context = canvas.getContext("2d", {willReadFrequently: true})
          context.drawImage(video, 0, 0, 64, 64)
          resolve({mediaTime: metadata.mediaTime, pixel: Array.from(context.getImageData(32, 32, 1, 1).data)})
        }
        callback = video.requestVideoFrameCallback(presented)
      })
      video.currentTime = time
      return decoded
    }
    return {ready: true}
  }, {codecs: fixture.codecs, initPath, mediaPath, fragments: fixture.fragments, highWater: fixture.high_water})
}

test("recovered committed CMAF ranges decode distinct frames after forward and backward seeks", async ({page}) => {
  requests.length = 0
  expect(await openRecording(page)).toEqual({ready: true})
  // Expectations come from the invented RGB source, independently of packager
  // timestamps and the returned pixels. All four reads start at an IDR boundary.
  for (const [sequence, time, channel] of [[0, 0.5, 0], [2, 4.5, 2], [1, 2.5, 1], [0, 0.5, 0]]) {
    const frame = await page.evaluate(({sequence, time}) => window.seekRecordedFrame(sequence, time), {sequence, time})
    console.info(JSON.stringify({sequence, requestedTime: time, ...frame}))
    expect(Math.abs(frame.mediaTime - time)).toBeLessThanOrEqual(1 / 15)
    expect(frame.pixel[channel]).toBeGreaterThan(220)
    for (const other of [0, 1, 2].filter(value => value !== channel)) expect(frame.pixel[other]).toBeLessThan(30)
    expect(frame.pixel[3]).toBe(255)
  }
  expect(requests).toEqual([0, 2, 1, 0])
})

test("Chromium rejects a corrupt initialization box at the real append boundary", async ({page}) => {
  expect(await openRecording(page, "/invalid-init")).toEqual({error: "source-buffer-error"})
})

test("a mismatched Content-Range cannot supply a frame for the requested fragment", async ({page}) => {
  expect(await openRecording(page, "/init", "/invalid-range")).toEqual({ready: true})
  await expect(page.evaluate(() => window.seekRecordedFrame(2, 4.5))).rejects.toThrow("invalid-fragment-range")
})
