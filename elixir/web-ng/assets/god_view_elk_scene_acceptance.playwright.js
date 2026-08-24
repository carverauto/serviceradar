import {expect, test} from "@playwright/test"
import {mkdir, readdir} from "node:fs/promises"
import {resolve} from "node:path"

import {
  groupGeometryViolations,
  routeInsideSafeRect,
  routeInteriorsIntersect,
  routeStrokeHitsBox,
  segmentAabbDistance,
} from "./js/lib/god_view/acceptance_geometry_assertions.js"

const OUTPUT_DIR = process.env.TEST_UNDECLARED_OUTPUTS_DIR
if (!OUTPUT_DIR) throw new Error("TEST_UNDECLARED_OUTPUTS_DIR is required")
const BUNDLE = resolve(
  process.env.TEST_SRCDIR,
  process.env.TEST_WORKSPACE,
  process.env.GOD_VIEW_ACCEPTANCE_BUNDLE,
)

test.use({
  viewport: {width: 1920, height: 1080},
  deviceScaleFactor: 1,
  reducedMotion: "reduce",
  colorScheme: "dark",
  channel: "chromium",
})

function overlaps(a, b, epsilon = 0.5) {
  return Math.min(a.right, b.right) - Math.max(a.left, b.left) > epsilon
    && Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top) > epsilon
}

function inside(box, safe, epsilon = 1) {
  return box.left >= safe.left - epsilon
    && box.top >= safe.top - epsilon
    && box.right <= safe.right + epsilon
    && box.bottom <= safe.bottom + epsilon
}

function assertScene(snapshot, expected) {
  expect(snapshot.counts).toEqual(expected)
  expect(snapshot.glyphs).toHaveLength(expected.renderedGlyphs)
  expect(snapshot.routes).toHaveLength(expected.renderedRoutes)
  expect(snapshot.labels).toHaveLength(expected.admittedLabels)
  expect(groupGeometryViolations(snapshot)).toEqual([])

  for (let left = 0; left < snapshot.nodes.length; left += 1) {
    for (let right = left + 1; right < snapshot.nodes.length; right += 1) {
      const pair = [snapshot.nodes[left], snapshot.nodes[right]]
      expect(overlaps(pair[0].box, pair[1].box), `${pair[0].id} overlaps ${pair[1].id}`).toBe(false)
    }
  }

  for (let left = 0; left < snapshot.routes.length; left += 1) {
    for (let right = left + 1; right < snapshot.routes.length; right += 1) {
      const a = snapshot.routes[left]
      const b = snapshot.routes[right]
      expect(routeInteriorsIntersect(a, b), `${a.id} intersects ${b.id}`).toBe(false)
    }
  }

  for (let left = 0; left < snapshot.labels.length; left += 1) {
    const label = snapshot.labels[left]
    expect(inside(label.box, snapshot.safeRect), `${label.nodeId} label leaves safe rect`).toBe(true)
    for (let right = left + 1; right < snapshot.labels.length; right += 1) {
      expect(overlaps(label.box, snapshot.labels[right].box), `${label.nodeId} label collision`).toBe(false)
    }
    for (const glyph of snapshot.glyphs) {
      if (glyph.nodeId === label.nodeId) continue
      expect(overlaps(label.box, glyph), `${label.nodeId} label hits ${glyph.nodeId}`).toBe(false)
    }
    for (const route of snapshot.routes) {
      expect(routeStrokeHitsBox(route, label.box), `${label.nodeId} label hits ${route.id}`).toBe(false)
    }
  }
  for (const glyph of snapshot.glyphs) {
    expect(inside(glyph, snapshot.safeRect), `${glyph.nodeId} glyph leaves safe rect`).toBe(true)
  }
  for (const route of snapshot.routes) {
    expect(routeInsideSafeRect(route, snapshot.safeRect), `${route.id} route leaves safe rect`).toBe(true)
    for (const glyph of snapshot.glyphs) {
      if (glyph.nodeId === route.sourceId || glyph.nodeId === route.targetId) continue
      const distances = route.projectedPoints.slice(1).map((point, index) =>
        segmentAabbDistance(route.projectedPoints[index], point, glyph))
      const clearance = Math.min(...distances) - (route.strokeWidth / 2)
      expect(
        routeStrokeHitsBox(route, glyph),
        `${route.id} hits nonincident glyph ${glyph.nodeId}; stroke=${route.strokeWidth}; clearance=${clearance}; glyph=${JSON.stringify(glyph)}`,
      ).toBe(false)
    }
  }
}

function stableGeometry(snapshot) {
  return {
    profileKey: snapshot.profileKey,
    counts: snapshot.counts,
    nodes: snapshot.nodes,
    groups: snapshot.groups,
    routes: snapshot.routes.map(({projectedPoints: _projected, box: _box, ...route}) => route),
  }
}

async function phase(page, context, name, nextName) {
  const screenshot = resolve(OUTPUT_DIR, `${name}.png`)
  const trace = resolve(OUTPUT_DIR, `${name}.trace.zip`)
  await page.screenshot({path: screenshot, animations: "disabled"})
  await context.tracing.stop({path: trace})
  if (nextName) {
    await context.tracing.start({screenshots: true, snapshots: true, sources: true, title: nextName})
  }
}

test("gates the canonical God-View ELK scene through the production renderer", async ({page, context}) => {
  await mkdir(OUTPUT_DIR, {recursive: true})
  await context.tracing.start({screenshots: true, snapshots: true, sources: true, title: "collapsed"})
  await page.setContent(`<!doctype html>
    <meta charset="utf-8">
    <style>
      * { animation: none !important; transition: none !important; caret-color: transparent !important; }
      html, body { margin: 0; width: 1920px; height: 1080px; overflow: hidden; background: #071018; }
      #god-view-fixture { position: relative; width: 1920px; height: 1080px; overflow: hidden; }
      #god-view-fixture > canvas { position: absolute; inset: 0; display: block; }
      #god-view-fixture [data-god-view-safe-area="status"] { position: absolute; bottom: 12px; left: 12px; width: max-content; }
      #god-view-fixture > .hidden { display: none; }
      .sr-god-view-map-controls { position: absolute; right: 12px; bottom: 12px; z-index: 40; display: inline-flex; gap: 6px; }
      .sr-ops-map-control-button { min-width: 30px; height: 30px; }
    </style>
    <div id="god-view-fixture"></div>`)
  await page.addScriptTag({path: BUNDLE})
  await page.waitForFunction(() => window.__SR_GOD_VIEW_HARNESS__)
  await page.evaluate(() => document.fonts.ready)

  const collapsedResult = await page.evaluate(() => window.__SR_GOD_VIEW_HARNESS__.renderFixture("collapsed"))
  assertScene(collapsedResult.snapshot, {
    semanticNodes: 30, semanticEdges: 34, attachmentEdges: 24, renderedRoutes: 32, renderedGlyphs: 30, admittedLabels: 8,
  })
  await phase(page, context, "collapsed", "expanded")

  const expandedResult = await page.evaluate(() => window.__SR_GOD_VIEW_HARNESS__.renderFixture("expanded"))
  expect(expandedResult.snapshot.groups).toHaveLength(1)
  expect(expandedResult.snapshot.groups[0].memberIds).toHaveLength(24)
  assertScene(expandedResult.snapshot, {
    semanticNodes: 54, semanticEdges: 58, attachmentEdges: 48, renderedRoutes: 32, renderedGlyphs: 53, admittedLabels: 26,
  })
  await phase(page, context, "expanded", "fit")

  const firstFit = await page.evaluate(() => window.__SR_GOD_VIEW_HARNESS__.fit())
  const secondFit = await page.evaluate(() => window.__SR_GOD_VIEW_HARNESS__.fit())
  expect(secondFit.viewState).toEqual(firstFit.viewState)
  expect(secondFit.glyphs).toEqual(firstFit.glyphs)
  expect(secondFit.labels).toEqual(firstFit.labels)
  await phase(page, context, "fit", "concurrent-expanded")

  const focused = await page.evaluate(() => window.__SR_GOD_VIEW_HARNESS__.focus())
  expect(focused.viewState).not.toEqual(secondFit.viewState)

  const concurrentResult = await page.evaluate(() => window.__SR_GOD_VIEW_HARNESS__.renderFixture("concurrent"))
  expect(concurrentResult.snapshot.groups).toHaveLength(2)
  assertScene(concurrentResult.snapshot, {
    semanticNodes: 78, semanticEdges: 82, attachmentEdges: 72, renderedRoutes: 32, renderedGlyphs: 76, admittedLabels: 38,
  })
  const concurrentGeometry = stableGeometry(concurrentResult.snapshot)
  await phase(page, context, "concurrent-expanded", "profile-threshold")

  await page.evaluate(() => window.__SR_GOD_VIEW_HARNESS__.renderFixture("second"))
  const reexpanded = await page.evaluate(() => window.__SR_GOD_VIEW_HARNESS__.renderFixture("concurrent"))
  expect(stableGeometry(reexpanded.snapshot)).toEqual(concurrentGeometry)

  const portrait = await page.evaluate(() => window.__SR_GOD_VIEW_HARNESS__.profile(800, 1000))
  expect(portrait.profileKey).not.toEqual(concurrentResult.snapshot.profileKey)
  expect(portrait.profileKey).toMatch(/portrait/)
  await context.tracing.stop({path: resolve(OUTPUT_DIR, "profile-threshold.trace.zip")})
  expect((await readdir(OUTPUT_DIR)).sort()).toEqual([
    "collapsed.png",
    "collapsed.trace.zip",
    "concurrent-expanded.png",
    "concurrent-expanded.trace.zip",
    "expanded.png",
    "expanded.trace.zip",
    "fit.png",
    "fit.trace.zip",
    "profile-threshold.trace.zip",
  ])
})
