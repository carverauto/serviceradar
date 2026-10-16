import {expect, test} from "@playwright/test"
import {resolve} from "node:path"
import {transportTile, transportDetail} from "./js/lib/god_view/fixtures/world_transport.js"

const html = resolve(process.env.TEST_SRCDIR, process.env.TEST_WORKSPACE, process.env.GOD_VIEW_WORLD_GPU_PAGE)

async function completedBitmapFrame(page) {
  const before = await page.evaluate(() => {
    const {measurements} = window.__SR_BITMAP_GPU__
    measurements.recordFrames = true
    return measurements.frames.length
  })
  await page.waitForFunction(before => window.__SR_BITMAP_GPU__.measurements.frames.length > before, before)
  await page.evaluate(() => {window.__SR_BITMAP_GPU__.measurements.recordFrames = false})
}

test("binary overlays survive refinement, reconnect and device teardown", async ({page}) => {
  await page.route("http://localhost:4774/**", route => route.fulfill({path: html, contentType: "text/html"}))
  await page.goto("http://localhost:4774/?bitmap=1")
  await page.getByRole("button", {name: "Zoom tiles", exact: true}).click()
  await page.getByRole("button", {name: "Toggle query", exact: true}).click()
  const active = () => page.waitForFunction(() => {
    const {renderer, samples} = window.__SR_BITMAP_GPU__
    return renderer.channel?.state === "joined" && renderer.cache.watch && samples.acknowledgements > 0 &&
      !renderer.membership.pending && renderer.membership.entries.size > 0 && renderer.overlays.entries.size > 0 &&
      renderer.deck.props.layers[0].isLoaded && renderer.membership.entries.size === renderer.cache.visible.size &&
      [...renderer.cache.visible.keys()].every(key => renderer.membership.entries.get(key)?.revision === renderer.cache.entries.get(key)?.geometry.revision)
  })
  const transition = async (button, target, zoom) => {
    const before = await page.evaluate(() => {
      const {renderer, samples} = window.__SR_BITMAP_GPU__
      return {keys: [...renderer.cache.visible.keys()].sort().join(","), sequence: renderer.membership.sequence.toString(), acks: samples.acknowledgements}
    })
    await page.getByRole("button", {name: button, exact: true}).click()
    await page.waitForFunction(({before, target, zoom}) => {
      const {renderer, samples} = window.__SR_BITMAP_GPU__, view = renderer.deck.getViewports()[0]
      return view.zoom === zoom && view.target[0] === target[0] && view.target[1] === target[1] &&
        [...renderer.cache.visible.keys()].sort().join(",") !== before.keys &&
        renderer.membership.sequence > BigInt(before.sequence) && samples.acknowledgements > before.acks
    }, {before, target, zoom})
    await active()
    await completedBitmapFrame(page)
  }
  await active()
  for (let cycle = 0; cycle < 4; cycle += 1) {
    await transition("Overview tiles", [256, 256], 0.5)
    await transition("Pan tiles", [64 + ((cycle + 1) * 97) % 384, 64 + ((cycle + 1) * 73) % 384], 3)
  }
  for (const name of ["Disconnect socket", "Change authority"]) {
    const before = await page.evaluate(() => window.__SR_BITMAP_GPU__.samples.acknowledgements)
    await page.getByRole("button", {name, exact: true}).click()
    await page.waitForFunction(before => window.__SR_BITMAP_GPU__.samples.acknowledgements > before, before)
    await active()
    await completedBitmapFrame(page)
  }
  const retained = await page.evaluate(() => window.__SR_BITMAP_GPU__.metrics())
  expect(retained.rendererMode).toBe("webgpu")
  expect(retained.geometryEntries).toBeLessThanOrEqual(64)
  expect(retained.membershipRetainedBytes + retained.overlayChargedBytes).toBeLessThanOrEqual(8 * 1024 * 1024)
  expect(retained.errors).toEqual([])
  await page.getByRole("button", {name: "Toggle binary", exact: true}).click()
  await expect(page.getByRole("status")).toContainText("filtering is disabled")
  expect(await page.evaluate(() => window.__SR_BITMAP_GPU__.metrics().membershipRetainedBytes)).toBe(0)
  await page.getByRole("button", {name: "Teardown renderer", exact: true}).click()
  await page.waitForFunction(() => window.__SR_BITMAP_GPU__.metrics().gpuDevices === 0)
  expect(await page.evaluate(() => window.__SR_BITMAP_GPU__.metrics().gpuBufferBytes)).toBe(0)
  await page.getByRole("button", {name: "Remount renderer", exact: true}).click()
  await page.waitForFunction(() => window.__SR_BITMAP_GPU__.metrics().gpuDevices === 1)
  await page.getByRole("button", {name: "Teardown renderer", exact: true}).click()
  await page.waitForFunction(() => window.__SR_BITMAP_GPU__.metrics().gpuDevices === 0)
  expect(await page.evaluate(() => window.__SR_BITMAP_GPU__.metrics().errors)).toEqual([])
})

test("hidden membership and availability glyphs cannot pick or obscure a visible glyph", async ({page}) => {
  await page.route("http://localhost:4774/**", route => route.fulfill({path: html, contentType: "text/html"}))
  await page.goto("http://localhost:4774/?bitmap=1&capture=1")
  await page.waitForFunction(() => {
    const renderer = window.__SR_BITMAP_GPU__?.renderer
    return renderer?.cache.watch && renderer.deck.props.layers[0]?.isLoaded && renderer.cache.entries.size > 0
  })
  const pick = () => page.evaluate(async () => {
    const {deck} = window.__SR_BITMAP_GPU__.renderer
    const [x, y] = deck.getViewports()[0].project([192, 192, 0])
    const result = await deck.pickObjectAsync({x, y, radius: 6})
    const source = result?.sourceLayer || result?.layer
    const object = result?.object || (result?.picked && source?.props.data.resolve?.(result.index))
    return object ? {id: object.id, count: object.count, source: source.id} : null
  })
  await completedBitmapFrame(page)
  expect(await pick()).toMatchObject({id: "synthetic-aggregate-5", count: 60})
  await page.evaluate(() => window.__SR_WORLD_TRANSPORT__.events.get("god_view:set_bitmap_query")({query: {facet: "vlan", value: "99"}}))
  await page.waitForFunction(() => !window.__SR_BITMAP_GPU__.renderer.membership.pending && window.__SR_BITMAP_GPU__.renderer.membership.total === 0)
  await completedBitmapFrame(page)
  expect(await pick()).toBeNull()
  await page.evaluate(() => window.__SR_WORLD_TRANSPORT__.events.get("god_view:set_bitmap_query")({query: {all: []}}))
  await page.waitForFunction(() => !window.__SR_BITMAP_GPU__.renderer.membership.pending && window.__SR_BITMAP_GPU__.renderer.membership.total === 1024)
  await completedBitmapFrame(page)
  expect(await pick()).toMatchObject({id: "synthetic-aggregate-5", count: 60})
  // At the public tile-layer boundary, put identical geometry underneath a
  // hidden tile. A canceled picking callback cannot reveal the lower glyph.
  await page.evaluate(() => {clearInterval(window.__SR_BITMAP_GPU__.renderer.timer)})
  for (const state of ["zero", "pending", "stale", "availability"]) {
    await page.evaluate(state => {
      const {renderer} = window.__SR_BITMAP_GPU__
      const layer = window.__SR_BITMAP_GPU__.pickingLayer ||= renderer.deck.props.layers[0]
      const geometry = [...renderer.cache.entries.values()].map(entry => entry.geometry).find(tile => tile.nodes.some(node => node.id === "synthetic-aggregate-5"))
      const membership = renderer.membership.entries
      const changed = new Map([...membership].map(([key, entry]) => [key, {...entry,
        revision: state === "stale" ? "expired-receipt" : entry.revision,
        mask: state === "zero" ? new Uint8Array(entry.mask.length) : entry.mask,
        counts: state === "zero" ? new Uint32Array(entry.counts.length) : entry.counts,
      }]))
      // Public layer inputs: the hidden foreground must not intercept the
      // independently visible base geometry underneath it.
      renderer.deck.setProps({layers: [
        layer.clone({membershipEnabled: false, membershipPending: false, membership: null, filters: {}, links: false})
          .renderSubLayers({id: "visible-underlay", data: geometry}),
        layer.clone({membershipEnabled: true, membershipPending: state === "pending", membership: changed, links: false,
          filters: state === "availability" ? {healthy: false, unavailable: false, unknown: false} : {}})
          .renderSubLayers({id: "hidden-foreground", data: geometry}),
      ]})
    }, state)
    await completedBitmapFrame(page)
    expect(await pick(), state).toMatchObject({id: "synthetic-aggregate-5", count: 60, source: expect.stringContaining("visible-underlay")})
  }
  await page.evaluate(() => window.__SR_BITMAP_GPU__.renderer.destroy())
  await page.waitForFunction(() => window.__SR_BITMAP_GPU__.metrics().gpuDevices === 0)
  expect(await page.evaluate(() => window.__SR_BITMAP_GPU__.metrics().errors)).toEqual([])
})

test("compute pipelines retain their own bindings after another pipeline retires its input", async ({page}) => {
  await page.route("http://localhost:4774/", route => route.fulfill({path: html, contentType: "text/html"}))
  await page.goto("http://localhost:4774/")
  await expect(page.locator("#status")).toContainText("decoded tiles=4")
  const result = await page.evaluate(async () => {
    const {device} = window.__SR_WORLD_GPU_SMOKE__.deck
    const input = device.createBuffer({data: new Uint32Array([7]), usage: GPUBufferUsage.STORAGE})
    const nextInput = device.createBuffer({data: new Uint32Array([19]), usage: GPUBufferUsage.STORAGE})
    const output = device.createBuffer({byteLength: 4, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC})
    const makePipeline = increment => {
      const shader = device.createShader({stage: "compute", source: `
        @group(0) @binding(0) var<storage, read> source: array<u32>;
        @group(0) @binding(1) var<storage, read_write> result: array<u32>;
        @compute @workgroup_size(1) fn main() { result[0] = source[0] + ${increment}u; }
      `})
      return {shader, pipeline: device.createComputePipeline({shader, shaderLayout: {bindings: [
        {name: "source", type: "storage", group: 0, location: 0},
        {name: "result", type: "storage", group: 0, location: 1},
      ]}})}
    }
    const first = makePipeline(0)
    const second = makePipeline(1)
    const dispatch = pipeline => {
      const pass = device.beginComputePass({})
      pass.setPipeline(pipeline)
      pass.dispatch(1)
      pass.end()
      device.submit()
    }
    device.handle.pushErrorScope("validation")
    first.pipeline.setBindings({source: input, result: output})
    dispatch(first.pipeline)
    second.pipeline.setBindings({source: nextInput, result: output})
    dispatch(second.pipeline)
    await device.handle.queue.onSubmittedWorkDone()
    input.destroy()
    first.pipeline.setBindings({source: nextInput, result: output})
    dispatch(first.pipeline)
    const error = (await device.handle.popErrorScope())?.message ?? null
    const bytes = error ? null : await output.readAsync()
    const value = bytes ? new DataView(bytes.buffer, bytes.byteOffset, 4).getUint32(0, true) : null
    for (const resource of [first.pipeline, first.shader, second.pipeline, second.shader, nextInput, output]) resource.destroy()
    return {error, value}
  })
  expect(result).toEqual({error: null, value: 19})
})

test("HTTP bootstrap recovers and search, picking, detail return and invalidation share retained tiles", async ({page}) => {
  const version = "00000000-0000-4000-8000-000000000478"
  const revision = "a".repeat(64)
  const errors = []
  const tileRequests = []
  let manifestRequests = 0
  let detailRequests = 0
  let watchId = 0
  let socket
  let joinRef
  page.on("pageerror", error => errors.push(error.message))
  await page.routeWebSocket("**/socket/websocket**", connection => {
    socket = connection
    connection.onMessage(raw => {
      const [join, ref, topic, event] = JSON.parse(raw)
      if (event === "phx_join") {
        joinRef = join
        connection.send(JSON.stringify([join, ref, topic, "phx_reply", {status: "ok", response: {layout_version: version, generation: 1}}]))
      } else if (event === "tiles:watch") {
        watchId += 1
        connection.send(JSON.stringify([join, ref, topic, "phx_reply", {status: "ok", response: {watch_id: watchId}}]))
      } else if (event === "heartbeat") {
        connection.send(JSON.stringify([join, ref, topic, "phx_reply", {status: "ok", response: {}}]))
      }
    })
  })
  await page.route("http://localhost:4774/**", async route => {
    const url = new URL(route.request().url())
    const headers = {"x-sr-topology-layout-version": version, "x-sr-topology-generation": "1"}
    if (url.pathname === "/") return route.fulfill({path: html, contentType: "text/html"})
    if (url.pathname === "/topology/tiles/manifest") {
      manifestRequests += 1
      if (manifestRequests === 1) return route.fulfill({status: 503, json: {error: "not_ready"}})
      return route.fulfill({json: {layout_version: version, generation: 1, zmax: 16, extent: 2 ** 24, node_count: 2, relation_count: 1, bounds: [[192 * 32768, 192 * 32768], [208 * 32768, 216 * 32768]]}})
    }
    if (url.pathname === "/topology/tiles/search") {
      expect(url.searchParams.get("device_id")).toBe("invented-device-a")
      return route.fulfill({json: {layout_version: version, generation: 1, device_id: "invented-device-a", x: 192 * 32768, y: 192 * 32768, zoom: 2}})
    }
    const tile = url.pathname.match(/\/topology\/tiles\/[^/]+\/(\d+)\/(\d+)\/(\d+)$/)
    if (tile) {
      const [, z, x, y] = tile.map(Number)
      const etag = `"${version}:${revision}"`
      const conditional = route.request().headers()["if-none-match"]
      tileRequests.push({id: `${z}/${x}/${y}`, conditional})
      if (conditional === etag) return route.fulfill({status: 304, headers: {...headers, etag}})
      const bytes = transportTile({z, x, y})
      return route.fulfill({body: Buffer.from(bytes), contentType: "application/vnd.apache.arrow.file", headers: {...headers, etag}})
    }
    if (url.pathname.startsWith("/topology/overlays/")) {
      const tileId = url.pathname.split("/").slice(-3).join("/")
      return route.fulfill({json: {layout_version: version, generation: 1, revision, tile_id: tileId,
        health: {glyphs: []}, flow: {edges: [{id: "invented-link", total_relations: 1, selected_relations: 1,
          forward: {status: "measured", animate: true, packets_per_second: 120, octets_per_second: 12000}, reverse: {status: "unknown", animate: false}}]}}})
    }
    if (url.pathname === "/topology/details") {
      expect(url.searchParams.get("id")).toBe("invented-device-a")
      expect(url.searchParams.get("kind")).toBe("device")
      return route.fulfill({json: {details: {device: {id: "invented-device-a", label: "Synthetic access"}, scene: {kind: "neighborhood", id: "invented-device-a"}}}})
    }
    if (url.pathname === "/topology/snapshot/latest") {
      detailRequests += 1
      const bytes = transportDetail()
      return route.fulfill({body: Buffer.from(bytes), contentType: "application/vnd.apache.arrow.file", headers: {...headers,
        "x-sr-god-view-schema": "3", "x-sr-god-view-revision": "1", "x-sr-god-view-generated-at": "2026-01-01T00:00:00Z"}})
    }
    return route.fulfill({status: 404})
  })
  await page.goto("http://localhost:4774/?transport=1")
  await expect(page.getByRole("status")).toContainText("HTTP 503")
  await expect(page.getByRole("status")).toContainText("2 devices", {timeout: 15000})
  await page.getByRole("button", {name: "Share map", exact: true}).click()
  await expect(page.getByRole("textbox", {name: "Map link", exact: true})).toBeVisible()
  await page.mouse.click(80, 450)
  await expect(page.getByRole("textbox", {name: "Map link", exact: true})).toBeHidden()
  await page.getByRole("button", {name: "Share map", exact: true}).click()
  await page.keyboard.press("Escape")
  await expect(page.getByRole("textbox", {name: "Map link", exact: true})).toBeHidden()
  await page.getByRole("button", {name: "Share map", exact: true}).click()
  await page.getByRole("button", {name: "Close map popup", exact: true}).click()
  await expect(page.getByRole("textbox", {name: "Map link", exact: true})).toBeHidden()
  await page.getByRole("textbox", {name: "Find device by ID"}).fill("invented-device-a")
  await page.getByRole("button", {name: "Find", exact: true}).click()
  await expect(page.getByRole("button", {name: "Open neighborhood"})).toBeVisible()
  await page.waitForFunction(() => {
    const viewport = window.__SR_WORLD_TRANSPORT__.renderer.deck.getViewports()[0]
    return viewport.zoom === 2 && viewport.target[0] === 192 && viewport.target[1] === 192
  })
  await page.waitForFunction(() => window.__SR_WORLD_TRANSPORT__.renderer.overlays.entries.size > 0)
  const location = await page.evaluate(() => {
    const renderer = window.__SR_WORLD_TRANSPORT__.renderer
    const [x, y] = renderer.deck.getViewports()[0].project([192, 192, 0])
    return {x, y, camera: renderer.viewState.target}
  })
  await page.mouse.click(location.x, location.y)
  await page.getByRole("button", {name: "Open neighborhood"}).click()
  await expect(page.getByRole("button", {name: "Back to map"})).toBeVisible()
  // Controls target the visible ELK scene; the retained map camera must stay put.
  const detailCamera = await page.evaluate(() => {
    const {renderer, events} = window.__SR_WORLD_TRANSPORT__
    const viewport = renderer.detailRenderer.context.state.deck.getViewports()[0]
    const camera = {zoom: viewport.zoom, target: viewport.target}
    events.get("god_view:set_zoom_mode")({mode: "global"})
    return camera
  })
  await expect.poll(() => page.evaluate(() =>
    window.__SR_WORLD_TRANSPORT__.renderer.detailRenderer.context.state.deck.getViewports()[0].zoom
  )).not.toBe(detailCamera.zoom)
  expect(await page.evaluate(() => window.__SR_WORLD_TRANSPORT__.renderer.deck.getViewports()[0].zoom)).toBe(2)
  await page.evaluate(() => window.__SR_WORLD_TRANSPORT__.events.get("god_view:reset_view")({}))
  await expect.poll(() => page.evaluate(() =>
    window.__SR_WORLD_TRANSPORT__.renderer.detailRenderer.context.state.deck.getViewports()[0].zoom
  )).toBeCloseTo(detailCamera.zoom, 5)
  await expect.poll(() => page.evaluate(() =>
    window.__SR_WORLD_TRANSPORT__.renderer.detailRenderer.context.state.deck.props.layers
      .some(layer => layer.id === "god-view-atmosphere-particles" && layer.props.data.length > 0)
  )).toBe(true)
  await page.evaluate(() => window.__SR_WORLD_TRANSPORT__.events.get("god_view:set_layers")({layers: {atmosphere: false}}))
  await expect.poll(() => page.evaluate(() =>
    window.__SR_WORLD_TRANSPORT__.renderer.detailRenderer.context.state.deck.props.layers
      .some(layer => layer.id === "god-view-atmosphere-particles")
  )).toBe(false)
  await page.evaluate(() => window.__SR_WORLD_TRANSPORT__.events.get("god_view:reset_view")({}))
  await expect(page.getByRole("button", {name: "Back to map"})).toBeVisible()
  const loaded = tileRequests.length
  await page.getByRole("button", {name: "Back to map"}).click()
  await expect.poll(() => page.evaluate(async ({x, y}) => {
    const renderer = window.__SR_WORLD_TRANSPORT__.renderer
    return (await renderer.deck.pickObjectAsync({x, y, radius: 6}))?.object?.id
  }, location)).toBe("invented-device-a")
  await page.mouse.click(location.x, location.y)
  await page.getByRole("button", {name: "Open neighborhood"}).click()
  await expect(page.getByRole("button", {name: "Back to map"})).toBeVisible()
  // Reopening a cached scene retains the operator's Traffic setting.
  expect(await page.evaluate(() => window.__SR_WORLD_TRANSPORT__.renderer.detailRenderer.context.state.layers.atmosphere)).toBe(false)
  await page.evaluate(() => window.__SR_WORLD_TRANSPORT__.events.get("god_view:set_layers")({layers: {atmosphere: true}}))
  await expect.poll(() => page.evaluate(() =>
    window.__SR_WORLD_TRANSPORT__.renderer.detailRenderer.context.state.deck.props.layers
      .some(layer => layer.id === "god-view-atmosphere-particles" && layer.props.data.length > 0)
  )).toBe(true)
  expect(detailRequests).toBe(1)
  await page.getByRole("button", {name: "Back to map"}).click()
  await page.waitForFunction(() => window.__SR_WORLD_TRANSPORT__.renderer.cache.watch?.id > 0)
  expect(await page.evaluate(() => window.__SR_WORLD_TRANSPORT__.renderer.viewState.target)).toEqual(location.camera)
  expect(tileRequests.length).toBe(loaded)
  socket.send(JSON.stringify([joinRef, null, "topology:tiles", "topology_invalidated", {
    layout_version: version, generation: 1, watch_id: watchId, dirty_tiles: ["2/1/1"], reset: false,
  }]))
  await expect.poll(() => tileRequests.length).toBe(loaded + 1)
  expect(tileRequests.at(-1)).toEqual({id: "2/1/1", conditional: `"${version}:${revision}"`})
  await page.evaluate(() => window.__SR_WORLD_TRANSPORT__.events.get("god_view:reset_view")({}))
  await page.waitForFunction(() => {
    const viewport = window.__SR_WORLD_TRANSPORT__.renderer.deck.getViewports()[0]
    return viewport.zoom > 4 && viewport.target[0] === 200 && viewport.target[1] === 204
  })
  await page.evaluate(() => window.__SR_WORLD_TRANSPORT__.events.get("god_view:set_zoom_mode")({mode: "global"}))
  await page.waitForFunction(() => window.__SR_WORLD_TRANSPORT__.renderer.deck.props.layers[0]?.isLoaded)
  const clusterLocation = await page.evaluate(() => {
    const viewport = window.__SR_WORLD_TRANSPORT__.renderer.deck.getViewports()[0]
    const [x, y] = viewport.project([200, 204, 0])
    return {x, y}
  })
  await expect.poll(() => page.evaluate(async ({x, y}) =>
    (await window.__SR_WORLD_TRANSPORT__.renderer.deck.pickObjectAsync({x, y, radius: 6}))?.object?.kind,
  clusterLocation)).toBe("aggregate")
  await page.mouse.click(clusterLocation.x, clusterLocation.y)
  await expect.poll(() => page.evaluate(() => window.__SR_WORLD_TRANSPORT__.renderer.deck.getViewports()[0].zoom)).toBe(2)
  await expect(page.getByRole("button", {name: "Show members", exact: true})).toBeHidden()
  await expect.poll(() => page.evaluate(() => {
    const renderer = window.__SR_WORLD_TRANSPORT__.renderer
    return [...renderer.cache.entries.values()].some(entry => entry.geometry.key.z === 2 && entry.geometry.nodes.filter(node => node.kind === "device").length === 2)
  })).toBe(true)
  await page.evaluate(() => window.__SR_WORLD_TRANSPORT__.renderer.destroy())
  await page.unrouteAll({behavior: "wait"})
  expect(errors).toEqual([])
})

// Real rendering/picking contract. RBE uses WebGPU on SwiftShader; the same
// RBE-built page is also checked on a physical GPU for the performance contract.
for (const deviceScaleFactor of [1, 2]) {
  test.describe(`world tiles at DPR ${deviceScaleFactor}`, () => {
    test.use({viewport: {width: 1280, height: 720}, deviceScaleFactor})

    test("retains label buffers until queued GPU work is submitted", async ({page}) => {
      const errors = []
      page.on("pageerror", error => errors.push(error.message))
      await page.route("http://localhost:4774/", route => route.fulfill({path: html, contentType: "text/html"}))
      await page.goto("http://localhost:4774/")
      await expect(page.locator("#status")).toContainText("decoded tiles=4")
      await page.waitForFunction(() => window.__SR_WORLD_GPU_SMOKE__.deck.layerManager.getLayers()
        .some(layer => layer.id.endsWith("-labels")))
      await page.evaluate(() => {
        const {deck} = window.__SR_WORLD_GPU_SMOKE__
        const labels = deck.layerManager.getLayers().find(layer => layer.id.endsWith("-labels"))
        deck.setProps({layers: [labels.clone({id: "rapid-labels",
          characterSet: Array.from({length: 95}, (_, i) => String.fromCharCode(32 + i)),
          data: [{position: [128, 128, 0], text: "host-0.example.test", textAnchor: "start", alignmentBaseline: "center"}],
        })]})
      })
      await page.waitForFunction(() => window.__SR_WORLD_GPU_SMOKE__.deck.layerManager.getLayers()
        .some(layer => layer.id === "rapid-labels-characters" && layer.isLoaded))
      const validationError = await page.evaluate(async () => {
        const {deck} = window.__SR_WORLD_GPU_SMOKE__
        deck.device.handle.pushErrorScope("validation")
        const copy = deck.device.createBuffer({byteLength: 4, usage: GPUBufferUsage.COPY_DST})
        const labels = deck.layerManager.getLayers().find(layer => layer.id === "rapid-labels")
        const queueLabelRead = () => {
          const characters = deck.layerManager.getLayers().find(layer => layer.id === "rapid-labels-characters")
          const sourceBuffer = characters.getAttributeManager().getAttributes().rowIndexes.getBuffer()
          // A real GPU command keeps this text attribute live until submission,
          // independently of whether this adapter interleaves its draw attributes.
          deck.device.commandEncoder.copyBufferToBuffer({sourceBuffer, destinationBuffer: copy, size: 4})
        }
        for (const count of [1, 128, 2, 256, 1]) {
          queueLabelRead()
          deck.setProps({layers: [labels.clone({id: "rapid-labels", data: Array.from({length: count}, (_, i) => ({
            position: [128 + i, 128, 0], text: `host-${i}.example.test`,
            textAnchor: "start", alignmentBaseline: "center",
          }))})]})
          deck.layerManager.updateLayers()
          deck.redraw("rapid label refinement")
        }
        queueLabelRead()
        deck.setProps({layers: []})
        deck.layerManager.updateLayers()
        deck.device.submit()
        copy.destroy()
        return (await deck.device.handle.popErrorScope())?.message ?? null
      })
      expect(validationError).toBeNull()
      // WebGPU validation errors arrive asynchronously after queue submission.
      await page.waitForTimeout(250)
      await expect(page.locator("#status")).not.toContainText("FAIL")
      expect(errors).toEqual([])
    })

    test("picks visible geometry and retains it across revisit and telemetry", async ({page}) => {
      const errors = []
      page.on("pageerror", error => errors.push(error.message))
      await page.route("http://localhost:4774/", route => route.fulfill({path: html, contentType: "text/html"}))
      await page.goto("http://localhost:4774/")
      await expect(page.locator("#status")).toContainText("GPU smoke: webgpu")
      await expect(page.locator("#status")).toContainText("decoded tiles=4")

      // Wait for the real picking pass before sending the one DOM click.
      const node = {x: 368, y: 129}
      await expect.poll(() => page.evaluate(async ({x, y}) => {
        const info = await window.__SR_WORLD_GPU_SMOKE__.deck.pickObjectAsync({x, y, radius: 0})
        return info?.object?.id ?? null
      }, node), {timeout: 15_000}).toBe("invented-router")
      const point = await page.evaluate(({x, y}) => {
        const rect = document.querySelector("#map").getBoundingClientRect()
        return {x: rect.left + x, y: rect.top + y}
      }, node)
      await page.mouse.click(point.x, point.y)
      await expect(page.locator("#status")).toContainText("picked=invented-router")
      const picked = await page.evaluate(async () => {
        const {deck} = window.__SR_WORLD_GPU_SMOKE__
        const [x, y] = deck.getViewports()[0].project([160, 160, 0])
        const edge = await deck.pickObjectAsync({x, y, radius: 4})
        const rectangle = await deck.pickObjectsAsync({x: 350, y: 115, width: 35, height: 30})
        const empty = await deck.pickObjectAsync({x: 20, y: 20, radius: 2})
        return {edge: edge?.object?.id, rectangle: rectangle.map(info => info.object.id), empty: empty?.object?.id ?? null}
      })
      expect(picked.edge).toBe("invented-link")
      expect(picked.rectangle).toContain("invented-router")
      expect(picked.empty).toBeNull()

      await page.locator("#zoom").click()
      await page.waitForFunction(() => window.__SR_WORLD_GPU_SMOKE__.samples.size > 4)
      const loaded = await page.evaluate(() => window.__SR_WORLD_GPU_SMOKE__.samples.size)
      await page.locator("#overview").click()
      await page.locator("#telemetry").click()
      await expect(page.locator("#status")).toContainText("health=unavailable")
      await expect.poll(() => page.evaluate(() => window.__SR_WORLD_GPU_SMOKE__.samples.size)).toBe(loaded)
      await page.waitForFunction(() => window.__SR_WORLD_GPU_SMOKE__.deck.getViewports()[0].zoom === 0.5)
      expect(await page.evaluate(() => window.__SR_WORLD_GPU_SMOKE__.samples.size)).toBe(loaded)
      await page.locator("#detail").click()
      await page.waitForFunction(() => document.querySelector("#status").textContent.startsWith("FAIL") || window.__SR_WORLD_GPU_SMOKE__.detail?.context.state.lastGraph?._layoutMode === "elk-scene-detail")
      await expect(page.locator("#status")).not.toContainText("FAIL")
      await page.waitForFunction(() => window.__SR_WORLD_GPU_SMOKE__.detail?.context.state.rendererMode === "webgpu")
      await page.locator("#close-detail").click()
      expect(await page.evaluate(() => window.__SR_WORLD_GPU_SMOKE__.samples.size)).toBe(loaded)
      await expect(page.locator("#status")).not.toContainText("FAIL")
      expect(errors).toEqual([])
    })
  })
}
