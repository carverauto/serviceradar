import {expect, test} from "@playwright/test"
import {readFile} from "node:fs/promises"
import {createServer} from "node:http"
import {resolve} from "node:path"

let server, origin, fixture, bundle, component, styles, held
let blockedPath = null
let failureStatus = null
const requests = []
const fixturePath = name => resolve(process.env.TEST_SRCDIR, process.env.TEST_WORKSPACE, process.env[name])
const sourceId = "11111111-1111-4111-8111-111111111111"
const blocks = {rgb: "22222222-2222-4222-8222-222222222222", blue: "33333333-3333-4333-8333-333333333333"}
const recordingPath = name => `/api/cameras/${sourceId}/recordings/${blocks[name]}`

function playlist(name) {
  const indexes = name === "blue" ? [2] : [0, 1, 2]
  return ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:2", "#EXT-X-PLAYLIST-TYPE:VOD",
    `#EXT-X-MEDIA-SEQUENCE:${indexes[0]}`, '#EXT-X-MAP:URI="init"',
    ...indexes.flatMap(index => ["#EXTINF:2,", `fragments/${index}`]), "#EXT-X-ENDLIST", ""].join("\n")
}

function send(res, bytes, type) {
  res.writeHead(200, {"Content-Type": type, "Content-Length": bytes.length, "Cache-Control": "private, no-store"})
  res.end(bytes)
}

function releaseHeld() {
  if (held) {
    const {res, bytes} = held
    held = null
    if (!res.destroyed) send(res, bytes, "video/mp4")
  }
}

test.beforeAll(async () => {
  fixture = JSON.parse(await readFile(fixturePath("CAMERA_BROWSER_FIXTURE"), "utf8"))
  bundle = await readFile(fixturePath("CAMERA_ARCHIVE_BUNDLE"))
  component = await readFile(fixturePath("CAMERA_ARCHIVE_COMPONENT"), "utf8")
  styles = await readFile(fixturePath("CAMERA_ARCHIVE_STYLES"))
  console.info(JSON.stringify({archiveHarnessBundleBytes: bundle.length}))
  server = createServer((req, res) => {
    if (req.url === "/") {
      res.setHeader("Set-Cookie", "fixture_session=synthetic; HttpOnly; SameSite=Lax; Path=/")
      send(res, Buffer.from(component.replace("</body>",
        '<canvas width="64" height="64" hidden></canvas><script src="/player.js"></script></body>')), "text/html")
      return
    }
    if (req.url === "/player.js") return send(res, bundle, "text/javascript")
    if (req.url === "/app.css") return send(res, styles, "text/css")
    const path = new URL(req.url, "http://example.test").pathname
    if (!req.url.startsWith("/api/cameras/")) { res.writeHead(404); res.end(); return }
    const entry = {path: req.url, range: req.headers.range || null, authenticated: req.headers.cookie === "fixture_session=synthetic", closed: false}
    requests.push(entry)
    res.on("close", () => { entry.closed = true })
    if (!entry.authenticated || entry.range) { res.writeHead(403); res.end(); return }
    if (path.endsWith("/playlist.m3u8")) {
      return send(res, Buffer.from(playlist(path.includes(`/${blocks.blue}/`) ? "blue" : "rgb")), "application/vnd.apple.mpegurl")
    }
    if (held || failureStatus) { res.writeHead(failureStatus || 503); res.end(); return }
    const index = /\/fragments\/(\d+)$/.exec(path)
    const encoded = path.endsWith("/init") ? fixture.init : fixture.fragments[Number(index?.[1])]?.base64
    if (!encoded) { res.writeHead(404); res.end(); return }
    const bytes = Buffer.from(encoded, "base64")
    if (path === blockedPath) {
      blockedPath = null
      held = {res, bytes, entry}
      return
    }
    send(res, bytes, "video/mp4")
  })
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve))
  origin = `http://127.0.0.1:${server.address().port}`
})

test.beforeEach(() => {
  releaseHeld()
  blockedPath = null
  failureStatus = null
  requests.length = 0
})

test.afterAll(async () => {
  releaseHeld()
  server.closeAllConnections()
  await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()))
})

async function frameAt(page, time, channel) {
  const frame = await page.evaluate(async time => {
    const video = document.querySelector("video")
    video.pause()
    const decoded = new Promise((resolve, reject) => {
      let callback
      const timer = setTimeout(() => {
        video.cancelVideoFrameCallback(callback)
        reject(new Error("decoded-frame-timeout"))
      }, 5_000)
      const sample = (_now, metadata) => {
        if (Math.abs(metadata.mediaTime - time) > 1 / 15) {
          callback = video.requestVideoFrameCallback(sample)
          return
        }
        clearTimeout(timer)
        const ctx = document.querySelector("canvas").getContext("2d", {willReadFrequently: true})
        ctx.drawImage(video, 0, 0, 64, 64)
        resolve({time: metadata.mediaTime, pixel: Array.from(ctx.getImageData(32, 32, 1, 1).data)})
      }
      callback = video.requestVideoFrameCallback(sample)
    })
    video.currentTime = time
    return decoded
  }, time)
  await expect.poll(() => page.locator("video").evaluate(video => video.seeking)).toBe(false)
  expect(Math.abs(frame.time - time)).toBeLessThanOrEqual(1 / 15)
  expect(frame.pixel[channel]).toBeGreaterThan(220)
  for (const other of [0, 1, 2].filter(value => value !== channel)) expect(frame.pixel[other]).toBeLessThan(30)
  expect(frame.pixel[3]).toBe(255)
  console.info(JSON.stringify({requestedTime: time, channel, ...frame}))
}

async function ready(page) {
  await expect.poll(() => page.locator("video").evaluate(video => video.readyState)).toBeGreaterThanOrEqual(2)
}

function assertWholeAuthenticatedReads() {
  expect(requests.length).toBeGreaterThan(0)
  expect(requests.every(request => request.authenticated && request.range === null)).toBe(true)
}

test("production HLS hook decodes forward and backward seeks using complete authenticated resources", async ({page}, testInfo) => {
  await page.goto(origin)
  await ready(page)
  expect(await page.locator("video").evaluate(video => video.paused)).toBe(true)
  for (const [time, channel] of [[0.5, 0], [4.5, 2], [2.5, 1], [0.5, 0]]) await frameAt(page, time, channel)
  assertWholeAuthenticatedReads()
  expect(requests.map(request => request.path)).toEqual([
    `${recordingPath("rgb")}/playlist.m3u8?first=0&count=3`, `${recordingPath("rgb")}/init`,
    ...[0, 1, 2].map(index => `${recordingPath("rgb")}/fragments/${index}`),
  ])
  // Capture controls after real playback, rather than during Chromium's native
  // loading-panel animation following a paused seek.
  await page.locator("video").evaluate(video => video.play())
  await expect.poll(() => page.locator("video").evaluate(video => video.currentTime)).toBeGreaterThan(0.7)
  await page.locator("video").evaluate(video => video.pause())
  for (const [name, width] of [["desktop", 1440], ["mobile", 390]]) {
    await page.setViewportSize({width, height: 900})
    await expect(page.getByRole("heading", {name: "Example gate camera"})).toBeVisible()
    await expect(page.getByRole("button", {name: "Previous window"})).toBeVisible()
    await expect(page.locator("video")).toBeVisible()
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
    console.info(JSON.stringify(await page.locator("video").evaluate(video => ({duration: video.duration, readyState: video.readyState, seeking: video.seeking, paused: video.paused}))))
    await page.screenshot({path: testInfo.outputPath(`archive-${name}.png`), fullPage: true})
  }
})

test("switching recordings cancels a delayed fragment, clears old frames and recovers only on explicit retry", async ({page}) => {
  blockedPath = `${recordingPath("rgb")}/fragments/1`
  await page.goto(origin)
  await ready(page)
  await frameAt(page, 0.5, 0)
  await expect.poll(() => held !== null).toBe(true)
  const oldRequest = held.entry
  await page.evaluate(path => {
    window.archiveHook.el.dataset.playlistPath = path
    window.archiveHook.updated()
  }, `${recordingPath("blue")}/playlist.m3u8`)
  await expect(page.getByRole("button", {name: "Retry playback"})).toBeVisible()
  await expect.poll(() => oldRequest.closed).toBe(true)
  await expect.poll(() => page.locator("video").evaluate(video => video.readyState)).toBe(0)
  const requestCount = requests.length
  // Watch longer than the upstream default first retry interval. The hook's
  // policy is no automatic retry, including when a cancelled provider is busy.
  await page.waitForTimeout(1500)
  expect(requests).toHaveLength(requestCount)
  releaseHeld()
  await page.getByRole("button", {name: "Retry playback"}).click()
  await ready(page)
  await frameAt(page, 0.5, 2)
  assertWholeAuthenticatedReads()
})

test("a seek that cancels a delayed read reports busy and decodes forward and backward after explicit retry", async ({page}) => {
  blockedPath = `${recordingPath("rgb")}/fragments/1`
  await page.goto(origin)
  await ready(page)
  await expect.poll(() => held !== null).toBe(true)
  const oldRequest = held.entry
  await page.locator("video").evaluate(video => { video.currentTime = 4.5 })
  await expect(page.getByRole("button", {name: "Retry playback"})).toBeVisible()
  expect(requests.some(request => request.path === `${recordingPath("rgb")}/fragments/2`)).toBe(true)
  await expect.poll(() => oldRequest.closed).toBe(true)
  expect(await page.locator("video").evaluate(video => video.readyState)).toBe(0)
  const count = requests.length
  await page.waitForTimeout(1500)
  expect(requests).toHaveLength(count)
  releaseHeld()
  await page.getByRole("button", {name: "Retry playback"}).click()
  await ready(page)
  await frameAt(page, 4.6, 2)
  await frameAt(page, 0.5, 0)
  assertWholeAuthenticatedReads()
})

test("denied bytes stop playback without automatic retries", async ({page}) => {
  failureStatus = 403
  await page.goto(origin)
  await expect(page.getByRole("button", {name: "Retry playback"})).toBeVisible()
  await expect(page.getByRole("status")).toContainText("Recording unavailable")
  const count = requests.length
  await page.waitForTimeout(1500)
  expect(requests).toHaveLength(count)
  expect(requests.filter(request => request.path.endsWith("/init"))).toHaveLength(1)
  expect(await page.locator("video").evaluate(video => video.readyState)).toBe(0)
})

test("destroy, pagehide and disconnect cancel pending media and leave no active video source", async ({page}) => {
  for (const resource of ["fragments/1", "init"]) {
    for (const lifecycle of ["destroyed", "pagehide", "disconnected"]) {
      blockedPath = `${recordingPath("rgb")}/${resource}`
      await page.goto(origin)
      if (resource !== "init") await ready(page)
      await expect.poll(() => held !== null).toBe(true)
      const oldRequest = held.entry
      await page.evaluate(lifecycle => {
        if (lifecycle === "pagehide") window.dispatchEvent(new PageTransitionEvent("pagehide"))
        else window.archiveHook[lifecycle]()
      }, lifecycle)
      await expect.poll(() => oldRequest.closed).toBe(true)
      expect(await page.locator("video").getAttribute("src")).toBeNull()
      expect(await page.locator("video").evaluate(video => video.readyState)).toBe(0)
      const count = requests.length
      releaseHeld()
      await page.waitForTimeout(100)
      expect(requests).toHaveLength(count)
      if (lifecycle !== "destroyed") {
        await page.evaluate(lifecycle => {
          if (lifecycle === "pagehide") window.dispatchEvent(new PageTransitionEvent("pageshow", {persisted: true}))
          else window.archiveHook.reconnected()
        }, lifecycle)
        await ready(page)
        await frameAt(page, 0.5, 0)
      }
    }
  }
})


test("an unresponsive fragment reaches the client deadline without retrying or retaining video", async ({page}) => {
  blockedPath = `${recordingPath("rgb")}/fragments/1`
  await page.goto(origin)
  await ready(page)
  await expect.poll(() => held !== null).toBe(true)
  const oldRequest = held.entry
  await expect(page.getByRole("button", {name: "Retry playback"})).toBeVisible({timeout: 14_000})
  await expect.poll(() => oldRequest.closed).toBe(true)
  expect(requests.filter(request => request.path === oldRequest.path)).toHaveLength(1)
  expect(await page.locator("video").evaluate(video => video.readyState)).toBe(0)
  releaseHeld()
})


test("switching actively playing media keeps loading status until the new recording is ready", async ({page}) => {
  await page.goto(origin)
  await ready(page)
  await page.locator("video").evaluate(video => video.play())
  await expect(page.getByRole("status")).toHaveText("Playing")
  blockedPath = `${recordingPath("blue")}/init`
  await page.evaluate(path => {
    window.archiveHook.el.dataset.playlistPath = path
    window.archiveHook.updated()
  }, `${recordingPath("blue")}/playlist.m3u8`)
  await expect.poll(() => held !== null).toBe(true)
  expect(requests.filter(request => request.path === `${recordingPath("blue")}/fragments/2`)).toHaveLength(0)
  await expect(page.getByRole("status")).toHaveText("Loading recording...")
  expect(await page.locator("video").evaluate(video => video.readyState)).toBe(0)
  releaseHeld()
  await ready(page)
  await frameAt(page, 0.5, 2)
})
