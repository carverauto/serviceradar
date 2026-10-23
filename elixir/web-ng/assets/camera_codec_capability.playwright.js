import {expect, test} from "@playwright/test"
import {readFile} from "node:fs/promises"
import {createServer} from "node:http"
import {resolve} from "node:path"

let fixture, server, origin

test.beforeAll(async () => {
  const path = resolve(process.env.TEST_SRCDIR, process.env.TEST_WORKSPACE, process.env.CAMERA_CODEC_FIXTURE)
  fixture = JSON.parse(await readFile(path, "utf8"))
  expect(fixture.scope).toBe("native_library_capability_only")
  expect(fixture.cases.map(row => row.name)).toEqual(["h264_aac", "h264_aac_delayed", "hevc_main8"])
  server = createServer((req, res) => {
    if (req.url !== "/") { res.writeHead(404); res.end(); return }
    res.writeHead(200, {"Content-Type": "text/html"})
    res.end('<!doctype html><title>Synthetic codec capability</title><video></video><canvas width="64" height="64"></canvas>')
  })
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve))
  origin = `http://127.0.0.1:${server.address().port}`
})

test.afterAll(async () => {
  if (server) await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()))
})

for (const name of ["h264_aac", "h264_aac_delayed", "hevc_main8"]) {
  test(`${name}: actual MSE playback and decoded markers define the bounded capability outcome`, async ({page, browser}) => {
    const row = fixture.cases.find(candidate => candidate.name === name)
    await page.goto(origin)
    const result = await page.evaluate(async row => {
      const video = document.querySelector("video")
      const media = new MediaSource()
      const objectURL = URL.createObjectURL(media)
      const audioTimes = [], frames = []
      let audio, processor, frameCallback, timer
      const bytes = text => Uint8Array.from(atob(text), char => char.charCodeAt(0))
      const event = (target, type) => new Promise((resolve, reject) => {
        const cleanup = () => { clearTimeout(deadline); target.removeEventListener(type, done); target.removeEventListener("error", failed) }
        const done = () => { cleanup(); resolve() }
        const failed = () => { cleanup(); reject(new Error(`${type}-error`)) }
        const deadline = setTimeout(() => { cleanup(); reject(new Error(`${type}-timeout`)) }, 5000)
        target.addEventListener(type, done, {once: true})
        target.addEventListener("error", failed, {once: true})
      })
      const advertised = MediaSource.isTypeSupported(row.mime)
      try {
        const opened = event(media, "sourceopen")
        video.src = objectURL
        await opened
        let buffer
        try { buffer = media.addSourceBuffer(row.mime) } catch (error) {
          if (error.name === "NotSupportedError") return {outcome: "unsupported", reason: "MSE addSourceBuffer rejected codec", advertised, mime: row.mime}
          throw error
        }
        for (const data of [row.init, ...row.fragments]) {
          const updated = event(buffer, "updateend")
          buffer.appendBuffer(bytes(data))
          await updated
        }
        media.endOfStream()
        if (row.audio_markers.length) {
          audio = new AudioContext({sampleRate: 48000})
          // Observe real media-element decoded audio. The output stays silent.
          processor = audio.createScriptProcessor(1024, 1, 1)
          audio.createMediaElementSource(video).connect(processor)
          processor.connect(audio.destination)
          processor.onaudioprocess = ({inputBuffer}) => {
            const audible = inputBuffer.getChannelData(0).some(sample => Math.abs(sample) > 0.1)
            if (audible && (!audioTimes.length || video.currentTime - audioTimes.at(-1) > 0.3)) audioTimes.push(video.currentTime)
          }
          await audio.resume()
        }
        const canvas = document.querySelector("canvas")
        const context = canvas.getContext("2d", {willReadFrequently: true})
        const presented = (_now, metadata) => {
          const target = [1, 3, 5][frames.length]
          if (target !== undefined && metadata.mediaTime >= target) {
            context.drawImage(video, 0, 0, 64, 64)
            frames.push({mediaTime: metadata.mediaTime, pixel: Array.from(context.getImageData(32, 32, 1, 1).data)})
          }
          frameCallback = video.requestVideoFrameCallback(presented)
        }
        frameCallback = video.requestVideoFrameCallback(presented)
        const ended = new Promise((resolve, reject) => {
          timer = setTimeout(() => reject(new Error("playback-deadline")), 10000)
          video.addEventListener("ended", resolve, {once: true})
          video.addEventListener("error", () => reject(new Error(`media-error-${video.error?.code}`)), {once: true})
        })
        await video.play()
        await ended
        return {outcome: "decoded", advertised, mime: row.mime, frames, audioTimes}
      } finally {
        clearTimeout(timer)
        if (frameCallback !== undefined) video.cancelVideoFrameCallback(frameCallback)
        video.pause()
        processor?.disconnect()
        if (audio) await audio.close()
        video.removeAttribute("src")
        video.load()
        URL.revokeObjectURL(objectURL)
      }
    }, row)
    console.info(JSON.stringify({browser: browser.version(), platform: process.platform, name, ...result}))
    if (name === "hevc_main8" && result.outcome === "unsupported") {
      expect(result.reason).toBe("MSE addSourceBuffer rejected codec")
      return
    }
    expect(result.outcome).toBe("decoded")
    expect(result.frames).toHaveLength(3)
    for (let channel = 0; channel < 3; channel++) {
      const frame = result.frames[channel]
      expect(Math.abs(frame.mediaTime - [1, 3, 5][channel])).toBeLessThan(0.2)
      expect(frame.pixel[channel]).toBeGreaterThan(220)
      for (const other of [0, 1, 2].filter(value => value !== channel)) expect(frame.pixel[other]).toBeLessThan(30)
    }
    if (row.audio_markers.length) {
      expect(result.audioTimes).toHaveLength(2)
      const offset = name === "h264_aac_delayed" ? 0.5 : 0
      // Browser scheduling/output buffering has its own finite observation budget;
      // the native sample/PTS checks own the tighter 50ms container diagnostic.
      for (let index = 0; index < 2; index++) expect(Math.abs(result.audioTimes[index] - [2, 4][index] - offset)).toBeLessThan(0.15)
    }
  })
}
