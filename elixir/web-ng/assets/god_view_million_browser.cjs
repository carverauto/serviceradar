// Browser acceptance over RBE-generated production Arrow bytes. This executable
// serves invented data on loopback; it does not build assets or contact a database.
const {strict: assert} = require("node:assert")
const {mkdtemp, readFile, rm, writeFile} = require("node:fs/promises")
const {tmpdir} = require("node:os")
const {join} = require("node:path")
const {createServer} = require("node:http")
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || "@playwright/test")

async function main() {
  const [fixturePath, pagePath] = process.argv.slice(2)
  const fixture = JSON.parse(await readFile(fixturePath, "utf8"))
  const html = await readFile(pagePath)
  const {manifest, samples, tiles} = fixture
  assert.equal(manifest.node_count, 1_000_000)
  assert.equal(manifest.relation_count, 2_000_000)
  const requests = []
  const missing = []
  let unhealthy = false
  let detailRequests = 0
  const server = createServer((request, response) => {
    const url = new URL(request.url, "http://localhost")
    const send = (status, body, type = "application/json", headers = {}) => {
      response.writeHead(status, {"Content-Type": type, ...headers})
      response.end(typeof body === "object" && !Buffer.isBuffer(body) ? JSON.stringify(body) : body)
    }
    if (url.pathname === "/") return send(200, html, "text/html")
    if (url.pathname === "/topology/tiles/manifest") return send(200, manifest)
    if (url.pathname === "/topology/tiles/search") {
      const sample = samples.find(item => item.device_id === url.searchParams.get("device_id"))
      return sample ? send(200, {...manifest, ...sample, scene: undefined}) : send(404, {})
    }
    if (url.pathname === "/topology/details") {
      const sample = samples.find(item => item.device_id === url.searchParams.get("id"))
      return sample ? send(200, {details: {device: {id: sample.device_id, label: sample.device_id}, scene: {kind: "neighborhood", id: sample.device_id}}}) : send(404, {})
    }
    const fence = {"x-sr-topology-layout-version": manifest.layout_version, "x-sr-topology-generation": String(manifest.generation)}
    if (url.pathname === "/topology/snapshot/latest") {
      const sample = samples.find(item => item.device_id === url.searchParams.get("id"))
      if (!sample) return send(404, {})
      detailRequests += 1
      return send(200, Buffer.from(sample.scene, "base64"), "application/vnd.apache.arrow.file", {...fence,
        "x-sr-god-view-schema": "3", "x-sr-god-view-revision": "1", "x-sr-god-view-generated-at": "2026-01-01T00:00:00Z"})
    }
    const match = url.pathname.match(/^\/topology\/(tiles|overlays)\/[^/]+\/(\d+\/\d+\/\d+)$/)
    if (match) {
      const [, kind, id] = match
      const tile = tiles[id]
      if (!tile) {missing.push(id); return send(404, {})}
      if (kind === "overlays") {
        const health = unhealthy ? {glyphs: tile.health.glyphs.map(glyph => ({...glyph, counts: {...glyph.counts, healthy: 0, unknown: 0, unavailable: glyph.counts.total}}))} : tile.health
        return send(200, {layout_version: manifest.layout_version, generation: 1, revision: tile.revision, tile_id: id, health, flow: tile.flow})
      }
      requests.push(id)
      const bytes = Buffer.from(tile.bytes, "base64")
      assert(bytes.length <= 262144)
      const etag = `"${manifest.layout_version}:${tile.revision}"`
      return request.headers["if-none-match"] === etag ? send(304, "", undefined, {...fence, etag}) : send(200, bytes, "application/vnd.apache.arrow.file", {...fence, etag})
    }
    return send(404, {})
  })
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve))
  const physical = process.env.GOD_VIEW_PHYSICAL_GPU === "1"
  const headless = !physical || process.env.GOD_VIEW_HEADLESS === "1"
  const frameRateLimitDisabled = physical && process.env.GOD_VIEW_UNCAPPED === "1"
  const energySaverOff = physical && process.env.GOD_VIEW_ENERGY_SAVER_OFF === "1"
  let browser
  let browserProfile
  try {
    // Uncapped throughput is an explicit diagnostic; normal physical validation
    // retains Chrome scheduling and fails if the pan/zoom SLO is not met.
    const viewport = {width: 1280, height: 720}
    const args = frameRateLimitDisabled ? ["--disable-frame-rate-limit"] : []
    if (energySaverOff) {
      // Low-battery Chrome caps even a blank page at 30 FPS. Disable Energy
      // Saver only in an owned disposable profile, preserving normal vsync.
      browserProfile = await mkdtemp(join(tmpdir(), "sr4774-physical-gpu-"))
      browser = await chromium.launchPersistentContext(browserProfile, {channel: "chrome", headless, args, viewport, deviceScaleFactor: 1})
      const settings = await browser.newPage()
      await settings.goto("chrome://settings/performance")
      const toggle = settings.locator("settings-toggle-button").filter({hasText: "Energy Saver"})
      await toggle.waitFor()
      if (await toggle.evaluate(node => node.checked)) await toggle.locator("cr-toggle").click()
      assert.equal(await toggle.evaluate(node => node.checked), false)
      await settings.close()
    } else {
      browser = await chromium.launch(physical ? {channel: "chrome", headless, args} : {headless: true, args: [
        "--enable-unsafe-webgpu", "--enable-unsafe-swiftshader", "--enable-features=Vulkan", "--use-vulkan=swiftshader", "--use-webgpu-adapter=swiftshader", "--use-angle=swiftshader",
      ]})
    }
    const page = energySaverOff ? await browser.newPage() : await browser.newPage({viewport, deviceScaleFactor: 1})
    const errors = []
    page.on("pageerror", error => errors.push(error.message))
    await page.routeWebSocket("**/socket/websocket**", connection => {
      let watch = 0
      connection.onMessage(raw => {
        const [join, ref, topic, event] = JSON.parse(raw)
        const result = event === "phx_join" ? {layout_version: manifest.layout_version, generation: 1} : event === "tiles:watch" ? {watch_id: ++watch} : {}
        connection.send(JSON.stringify([join, ref, topic, "phx_reply", {status: "ok", response: result}]))
      })
    })
    await page.goto(`http://127.0.0.1:${server.address().port}/?transport=1`)
    await page.waitForFunction(() => window.__SR_WORLD_TRANSPORT__?.measurements.firstFrame != null)
    const first = await page.evaluate(() => {
      const {renderer, measurements} = window.__SR_WORLD_TRANSPORT__
      return {milliseconds: measurements.firstFrame, count: renderer.cache.entries.get("0/0/0").geometry.nodes.reduce((sum, node) => sum + node.count, 0), zoom: renderer.deck.getViewports()[0].zoom}
    })
    assert.equal(first.count, 1_000_000)
    assert.equal(first.zoom, 0)
    const adapter = await page.evaluate(async () => {
      const adapter = await navigator.gpu.requestAdapter()
      return {info: {...adapter.info.toJSON?.(), vendor: adapter.info.vendor, architecture: adapter.info.architecture, isFallbackAdapter: adapter.info.isFallbackAdapter}, limits: {maxBufferSize: adapter.limits.maxBufferSize, maxVertexBuffers: adapter.limits.maxVertexBuffers}}
    })
    if (physical) assert.equal(adapter.info.isFallbackAdapter, false)
    // Flight and picked scene use the actual form and buttons, including a
    // device whose high-zoom glyph may still be generalized into an aggregate.
    for (const sample of samples) {
      await page.getByRole("textbox", {name: "Find device by ID"}).fill(sample.device_id)
      await page.getByRole("button", {name: "Find", exact: true}).click()
      await page.waitForFunction(({x, y, zoom}) => {
        const renderer = window.__SR_WORLD_TRANSPORT__.renderer
        const viewport = renderer.deck.getViewports()[0]
        return viewport.zoom === zoom && viewport.target[0] === x / 32768 && viewport.target[1] === y / 32768 && renderer.cache.pending.size === 0
      }, sample)
      await page.getByRole("button", {name: "Open neighborhood"}).click()
      await page.getByRole("button", {name: "Back to map"}).waitFor({state: "visible"})
      const count = requests.length
      await page.getByRole("button", {name: "Back to map"}).click()
      await page.waitForFunction(() => !window.__SR_WORLD_TRANSPORT__.renderer.detailRenderer)
      assert.equal(requests.length, count, "detail return must reuse retained geometry")
    }
    // Pan within the retained viewport and return using real pointer input.
    await page.waitForFunction(() => window.__SR_WORLD_TRANSPORT__.renderer.cache.pending.size === 0)
    const profile = process.env.GOD_VIEW_CPU_PROFILE ? await page.context().newCDPSession(page) : null
    if (profile) {
      await profile.send("Profiler.enable")
      await profile.send("Profiler.start")
    }
    const beforePan = requests.length
    await page.evaluate(() => {
      const measurements = window.__SR_WORLD_TRANSPORT__.measurements
      measurements.frames = []
      measurements.recordFrames = true
    })
    for (const direction of [1, -1]) {
      await page.mouse.move(600, 400)
      await page.mouse.down()
      await page.mouse.move(600 + direction * 24, 400, {steps: 30})
      await page.mouse.up()
    }
    await page.waitForFunction(() => window.__SR_WORLD_TRANSPORT__.renderer.cache.pending.size === 0)
    assert.equal(requests.length, beforePan, "nearby pan/revisit must use retained tiles")
    // Exercise controller zoom with packet flow active, then let its visible
    // tiles settle before checking the independent telemetry-cache contract.
    await page.mouse.move(640, 360)
    await page.mouse.wheel(0, -180)
    await page.waitForFunction(() => window.__SR_WORLD_TRANSPORT__.renderer.deck.getViewports()[0].zoom > 8.2)
    await page.mouse.wheel(0, 180)
    await page.waitForFunction(() => {
      const {renderer, measurements} = window.__SR_WORLD_TRANSPORT__
      const viewport = renderer.deck.getViewports()[0]
      const camera = JSON.stringify([viewport.zoom, viewport.target])
      if (measurements.settledCamera !== camera) {
        measurements.settledCamera = camera
        measurements.cameraChangedAt = performance.now()
      }
      return viewport.zoom < 8.1 && performance.now() - measurements.cameraChangedAt > 250 &&
        renderer.cache.pending.size === 0 && renderer.deck.props.layers[0].isLoaded
    })
    unhealthy = true
    const beforeTelemetry = requests.length
    await page.evaluate(() => window.__SR_WORLD_TRANSPORT__.renderer.overlays.poll())
    assert.equal(requests.length, beforeTelemetry, "telemetry must not refetch geometry")
    const metrics = await page.evaluate(async () => {
      const {renderer, measurements} = window.__SR_WORLD_TRANSPORT__
      await renderer.deck.device.handle.queue.onSubmittedWorkDone()
      measurements.recordFrames = false
      const viewport = renderer.deck.getViewports()[0]
      const times = []
      let picked = 0
      for (let index = 0; index < 20; index++) {
        const start = performance.now()
        const info = await renderer.deck.pickObjectAsync({x: viewport.width / 2 + index, y: viewport.height / 2, radius: 6})
        if (info?.object) picked += 1
        times.push(performance.now() - start)
      }
      const frames = measurements.frames
      const fps = frames.length > 1 ? (frames.length - 1) * 1000 / (frames.at(-1) - frames[0]) : 0
      const p95 = values => values.sort((a, b) => a - b)[Math.floor((values.length - 1) * 0.95)]
      const frameTimes = frames.slice(1).map((value, index) => value - frames[index])
      return {fps, frames: frames.length, frameP95: p95(frameTimes), slowestFrames: frameTimes.slice(-5), pickP95: p95(times), picked, tileP95: p95(measurements.loads), tileSamples: measurements.loads.length,
        packetLayers: renderer.deck.layerManager.getLayers().filter(layer => layer.id.endsWith("-packets") && layer.props.data.length > 0).length,
        rendererFailed: Boolean(renderer.rendererFailed)}
    })
    if (profile) {
      const {profile: result} = await profile.send("Profiler.stop")
      await writeFile(process.env.GOD_VIEW_CPU_PROFILE, JSON.stringify(result))
    }
    const report = {physical, headless, frameRateLimitDisabled, energySaverOff, adapter, first, metrics, detailRequests, geometryRequests: requests.length, serverFixture: fixture.measurements}
    console.log(JSON.stringify(report, null, 2))
    assert.equal(metrics.rendererFailed, false)
    assert(metrics.packetLayers > 0, "packet flow must be on")
    assert(metrics.picked > 0, "performance samples must include real selections")
    assert.deepEqual(errors, [])
    assert.deepEqual(missing, [], "fixture must cover every requested tile")
    if (physical) {
      assert(first.milliseconds <= 3000, "first usable frame exceeds 3s")
      assert(metrics.fps >= 30, "pan/zoom below 30 FPS")
      assert(metrics.pickP95 < 100, "picking exceeds 100ms")
      assert(metrics.tileP95 <= 200, "tile fetch/decode p95 exceeds 200ms")
    }
  } finally {
    try {await browser?.close()} finally {
      if (browserProfile) await rm(browserProfile, {recursive: true, force: true})
      await new Promise(resolve => server.close(resolve))
    }
  }
}
main().catch(error => {console.error(error); process.exitCode = 1})
