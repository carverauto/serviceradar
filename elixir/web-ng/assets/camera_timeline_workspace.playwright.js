import {expect, test} from "@playwright/test"
import {readFile} from "node:fs/promises"
import {createServer} from "node:http"
import {resolve} from "node:path"

let server, origin, fixture, bundle, component, styles
const fixturePath = name => resolve(process.env.TEST_SRCDIR, process.env.TEST_WORKSPACE, process.env[name])

function playlist() {
  return [
    "#EXTM3U",
    "#EXT-X-VERSION:7",
    "#EXT-X-TARGETDURATION:2",
    "#EXT-X-PLAYLIST-TYPE:VOD",
    "#EXT-X-MEDIA-SEQUENCE:0",
    '#EXT-X-MAP:URI="init"',
    "#EXTINF:2,",
    "fragments/0",
    "#EXTINF:2,",
    "fragments/1",
    "#EXTINF:2,",
    "fragments/2",
    "#EXT-X-ENDLIST",
    "",
  ].join("\n")
}

function send(res, bytes, type, extraHeaders = {}) {
  res.writeHead(200, {
    "Content-Type": type,
    "Content-Length": bytes.length,
    "Cache-Control": "private, no-store",
    ...extraHeaders,
  })
  res.end(bytes)
}

test.beforeAll(async () => {
  fixture = JSON.parse(await readFile(fixturePath("CAMERA_BROWSER_FIXTURE"), "utf8"))
  bundle = await readFile(fixturePath("CAMERA_TIMELINE_BUNDLE"))
  component = await readFile(fixturePath("CAMERA_TIMELINE_COMPONENT"), "utf8")
  styles = await readFile(fixturePath("CAMERA_TIMELINE_STYLES"))

  server = createServer((req, res) => {
    if (req.url === "/") {
      send(
        res,
        Buffer.from(component.replace("</body>", '<script src="/workspace.js"></script></body>')),
        "text/html"
      )
      return
    }
    if (req.url === "/workspace.js") return send(res, bundle, "text/javascript")
    if (req.url === "/app.css") return send(res, styles, "text/css")

    const path = new URL(req.url, "http://example.test").pathname
    if (path.endsWith("/playlist.m3u8")) {
      return send(res, Buffer.from(playlist()), "application/vnd.apple.mpegurl")
    }
    if (path.endsWith("/init")) {
      return send(res, Buffer.from(fixture.init, "base64"), "video/mp4", {"X-Recording-Copy": "local"})
    }
    const fragMatch = /\/fragments\/(\d+)$/.exec(path)
    if (fragMatch) {
      const encoded = fixture.fragments[Number(fragMatch[1])]?.base64
      if (encoded) {
        return send(res, Buffer.from(encoded, "base64"), "video/mp4", {"X-Recording-Copy": "local"})
      }
    }

    res.writeHead(404)
    res.end()
  })

  await new Promise(resolveListen => server.listen(0, "127.0.0.1", resolveListen))
  origin = `http://127.0.0.1:${server.address().port}`
})

test.afterAll(async () => {
  server.closeAllConnections()
  await new Promise((resolveClose, rejectClose) =>
    server.close(error => (error ? rejectClose(error) : resolveClose()))
  )
})

test("3-pane workspace renders cleanly across viewports, plays HLS with transport bar + AI overlay, and toggles Manage/Holds drawer", async ({
  page,
}, testInfo) => {
  await page.setViewportSize({width: 1440, height: 900})
  await page.goto(origin)

  // Verify 3-pane workspace elements on desktop
  await expect(page.locator("#camera-switcher-rail")).toBeVisible()
  await expect(page.locator("#camera-switcher-search")).toBeVisible()
  await expect(page.locator("#camera-switcher-filters")).toHaveCount(0)
  await expect(page.locator("#camera-switcher-total")).toHaveText("42")
  await expect(page.locator("#camera-switcher-page")).toHaveText("1/3")

  await expect(page.locator("#camera-timeline-coverage-section")).toBeVisible()
  await expect(page.locator("#camera-timeline-live-button")).toBeVisible()
  await expect(page.locator("#camera-timeline-zoom-in")).toBeVisible()
  await expect(page.locator("#camera-timeline-zoom-out")).toBeVisible()
  await expect(page.locator("#camera-timeline-coverage-bar")).toBeVisible()

  await expect(page.locator("#camera-timeline-player-section")).toBeVisible()
  await expect(page.locator("video[data-role='timeline-video']")).toBeVisible()

  // Verify compact 2-row x 6-column Detections & Clips grid (12 cards on page 1)
  const cards = page.locator("#camera-clips-grid [data-role='event-clip-card']")
  await expect(cards).toHaveCount(12)
  await expect(page.locator("#camera-clips-page-indicator")).toHaveText("Page 1 / 3")

  const rowGeometry = await cards.evaluateAll(nodes => {
    const tops = nodes.map(node => Math.round(node.getBoundingClientRect().top))
    const rows = new Map()
    for (const top of tops) {
      const bucket = Array.from(rows.keys()).find(key => Math.abs(key - top) <= 4) ?? top
      rows.set(bucket, (rows.get(bucket) || 0) + 1)
    }
    return Array.from(rows.values()).sort((a, b) => b - a)
  })
  expect(rowGeometry).toEqual([6, 6])

  // Wait for real HLS CMAF frames to decode via CameraTimelinePlayer
  await expect.poll(() => page.locator("video[data-role='timeline-video']").evaluate(v => v.readyState)).toBeGreaterThanOrEqual(2)
  await expect(page.locator("#camera-timeline-served-copy-badge")).toHaveText("Serving: local")

  // Seek to 0.5s where synthetic person bbox is active and verify SVG overlay renders
  await page.locator("video[data-role='timeline-video']").evaluate(v => {
    v.currentTime = 0.5
  })
  await expect.poll(() => page.locator("[data-role='semantic-bbox-item']").count()).toBe(1)

  // Transport controls: toggle mute & step forward/backward
  await page.locator("#camera-timeline-mute").click()
  await expect(page.locator("#camera-timeline-mute")).toHaveText("Unmute")
  await page.locator("#camera-timeline-fwd-10").click()
  await expect.poll(() => page.locator("video[data-role='timeline-video']").evaluate(v => v.currentTime)).toBeGreaterThan(1)
  await page.locator("#camera-timeline-back-10").click()
  await expect.poll(() => page.locator("video[data-role='timeline-video']").evaluate(v => v.currentTime)).toBeLessThan(0.5)

  // Return to 0.5s so AI bbox overlay is visible in the desktop screenshot
  await page.locator("video[data-role='timeline-video']").evaluate(v => {
    v.currentTime = 0.5
  })
  await expect.poll(() => page.locator("[data-role='semantic-bbox-item']").count()).toBe(1)

  // Verify zero horizontal overflow on desktop and capture desktop screenshot
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
  await page.screenshot({path: testInfo.outputPath("timeline-workspace-desktop.png"), fullPage: true})

  // Open Manage/Holds slide-over drawer, verify contents, capture screenshot, then close
  await expect(page.locator("#camera-timeline-manage-drawer")).toHaveAttribute("aria-hidden", "true")
  await page.locator("#camera-timeline-manage-drawer-toggle").click()
  await expect(page.locator("#camera-timeline-manage-drawer")).toHaveAttribute("aria-hidden", "false")
  await expect(page.locator("#camera-timeline-manage-drawer")).toBeVisible()
  await expect(page.locator("#place-timeline-hold-form")).toBeVisible()
  await expect(page.locator("#camera-timeline-blocks")).toBeVisible()
  await expect(page.locator("#camera-timeline-reanchors")).toBeVisible()
  await page.screenshot({path: testInfo.outputPath("timeline-workspace-drawer-open.png"), fullPage: false})

  await page.locator("#camera-timeline-manage-drawer-close").click()
  await expect(page.locator("#camera-timeline-manage-drawer")).toHaveAttribute("aria-hidden", "true")

  // Mobile viewport responsiveness check + screenshot
  await page.setViewportSize({width: 390, height: 900})
  await expect(page.locator("#camera-switcher-mobile-toggle")).toBeVisible()
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
  await page.screenshot({path: testInfo.outputPath("timeline-workspace-mobile.png"), fullPage: true})
})

test("vertical timeline rail click-to-seek fires single seek_timeline_fraction event, tracks hover, and does not interfere with detection markers", async ({
  page,
}) => {
  await page.setViewportSize({width: 1440, height: 900})
  await page.goto(origin)

  const rail = page.locator("#camera-timeline-coverage-bar")
  await expect(rail).toBeVisible()

  // Coverage buckets must be non-interactive elements (no nested button or phx-click)
  await expect(rail.locator("button[data-bucket-state]")).toHaveCount(0)
  await expect(rail.locator("[data-bucket-state][phx-click]")).toHaveCount(0)
  await expect(rail.locator("[data-bucket-state]")).toHaveCount(24)

  const box = await rail.boundingBox()
  expect(box).not.toBeNull()
  expect(box.height).toBeGreaterThan(100)

  // Hover updates crosshair and mouseleave hides it
  await page.mouse.move(box.x + box.width * 0.3, box.y + box.height * 0.4)
  await expect(rail.locator("[data-role='vertical-timeline-hover']")).toBeVisible()
  await page.mouse.move(box.x - 20, box.y - 20)
  await expect(rail.locator("[data-role='vertical-timeline-hover']")).toBeHidden()

  // Click at 25% and 75% down the rail (left side, away from right-edge marker ticks)
  await page.mouse.click(box.x + box.width * 0.25, box.y + box.height * 0.25)
  await page.mouse.click(box.x + box.width * 0.25, box.y + box.height * 0.75)

  const afterRailClicks = await page.evaluate(() => ({
    pushed: window.__timelinePushedEvents,
    clicks: window.__timelinePhxClicks,
  }))

  const seekEvents = afterRailClicks.pushed.filter(e => e.event === "seek_timeline_fraction")
  expect(seekEvents).toHaveLength(2)
  expect(seekEvents[0].payload.fraction).toBeGreaterThan(0.2)
  expect(seekEvents[0].payload.fraction).toBeLessThan(0.3)
  expect(seekEvents[1].payload.fraction).toBeGreaterThan(0.7)
  expect(seekEvents[1].payload.fraction).toBeLessThan(0.8)
  expect(afterRailClicks.clicks.filter(c => c.action === "select_timeline_bucket")).toHaveLength(0)

  // Click a detection event marker button on the vertical rail:
  // must dispatch select_event_clip and must NOT push another seek_timeline_fraction
  const marker = rail.locator("#camera-timeline-event-marker-0")
  await expect(marker).toBeVisible()
  await marker.click()

  const afterMarkerClick = await page.evaluate(() => ({
    pushed: window.__timelinePushedEvents,
    clicks: window.__timelinePhxClicks,
  }))

  expect(afterMarkerClick.pushed.filter(e => e.event === "seek_timeline_fraction")).toHaveLength(2)
  const markerClicks = afterMarkerClick.clicks.filter(c => c.action === "select_event_clip")
  expect(markerClicks).toHaveLength(1)
  expect(markerClicks[0].values.clip_id).toBe("evt-person-1")
})

test("recorded gaps popover renders reason summary, 10 newest-first items per page, pagination controls, and preserves open state via DetailsState across patches", async ({
  page,
}, testInfo) => {
  await page.setViewportSize({width: 1440, height: 900})
  await page.goto(origin)

  const details = page.locator("#camera-timeline-gaps-details")
  await expect(details).toBeVisible()
  await expect(details).toHaveAttribute("phx-hook", "DetailsState")
  expect(await details.evaluate(el => el.open)).toBe(false)
  await expect(details.locator("summary")).toHaveText("Gaps (25)")

  // DetailsState must register browser-owned `open` as ignored on mount
  const ignoredAttrs = await page.evaluate(() => window.__detailsIgnoredAttributes)
  expect(ignoredAttrs).toContainEqual({id: "camera-timeline-gaps-details", attrs: ["open"]})

  // Open the Gaps popover
  await details.locator("summary").click()
  expect(await details.evaluate(el => el.open)).toBe(true)

  // Verify reason summary strip sorted by count descending
  const summaryItems = page.locator("#camera-timeline-gaps-summary [data-role='timeline-gap-summary-item']")
  await expect(summaryItems).toHaveCount(3)
  await expect(page.locator("#camera-timeline-gap-summary-0")).toContainText("nvr_refused (http_503):")
  await expect(page.locator("#camera-timeline-gap-summary-0")).toContainText("19")
  await expect(page.locator("#camera-timeline-gap-summary-1")).toContainText("run_stopped (block_incomplete):")
  await expect(page.locator("#camera-timeline-gap-summary-1")).toContainText("5")
  await expect(page.locator("#camera-timeline-gap-summary-2")).toContainText("handover_overflow (buffer_full):")
  await expect(page.locator("#camera-timeline-gap-summary-2")).toContainText("1")

  // Verify Page 1 displays 10 newest-first gap rows with open newest outage at top
  const rows = page.locator("#camera-timeline-gaps [data-role='timeline-gap-item']")
  await expect(rows).toHaveCount(10)
  const rowIds = await rows.evaluateAll(nodes => nodes.map(n => n.id))
  expect(rowIds).toEqual(Array.from({length: 10}, (_, i) => `camera-timeline-gap-gap-${25 - i}`))
  await expect(page.locator("#camera-timeline-gap-gap-25")).toContainText("(open)")

  // Verify pagination controls on Page 1 / 3
  await expect(page.locator("#camera-timeline-gaps-page-indicator")).toHaveText("Page 1 / 3")
  await expect(page.locator("#camera-timeline-gaps-prev-page")).toBeDisabled()
  await expect(page.locator("#camera-timeline-gaps-next-page")).toBeEnabled()

  // Zero horizontal overflow with popover expanded + capture desktop visual evidence
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
  await page.screenshot({path: testInfo.outputPath("timeline-workspace-gaps-open.png"), fullPage: true})
  await details.screenshot({path: testInfo.outputPath("timeline-gaps-popover-open.png")})

  // Adversarial check: clicking Next triggers select_gaps_page(page=2) and a LiveView patch
  // stripping `open` is restored by DetailsState so the popover stays open.
  await page.locator("#camera-timeline-gaps-next-page").click()
  const pageClicks = await page.evaluate(() =>
    window.__timelinePhxClicks.filter(c => c.action === "select_gaps_page")
  )
  expect(pageClicks).toHaveLength(1)
  expect(pageClicks[0]).toEqual({action: "select_gaps_page", id: "camera-timeline-gaps-next-page", values: {page: "2"}})

  const openAfterSimulatedPatch = await page.evaluate(() => {
    const el = document.getElementById("camera-timeline-gaps-details")
    const hook = window.__detailsStateHooks["camera-timeline-gaps-details"]
    hook.beforeUpdate()
    el.removeAttribute("open")
    hook.updated()
    return el.open
  })
  expect(openAfterSimulatedPatch).toBe(true)

  // Verify mobile layout with Gaps popover open has zero horizontal overflow
  await page.setViewportSize({width: 390, height: 900})
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
  await page.screenshot({path: testInfo.outputPath("timeline-workspace-gaps-mobile.png"), fullPage: true})
})
