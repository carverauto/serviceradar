import {expect, test} from "@playwright/test"
import {mkdir} from "node:fs/promises"
import {resolve} from "node:path"

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

function orientation(a, b, c) {
  return ((b.x - a.x) * (c.y - a.y)) - ((b.y - a.y) * (c.x - a.x))
}

function properSegmentIntersection(a, b, c, d, epsilon = 0.01) {
  const abC = orientation(a, b, c)
  const abD = orientation(a, b, d)
  const cdA = orientation(c, d, a)
  const cdB = orientation(c, d, b)
  return ((abC > epsilon && abD < -epsilon) || (abC < -epsilon && abD > epsilon))
    && ((cdA > epsilon && cdB < -epsilon) || (cdA < -epsilon && cdB > epsilon))
}

function samePoint(a, b, epsilon = 0.01) {
  return Math.abs(a.x - b.x) <= epsilon && Math.abs(a.y - b.y) <= epsilon
}

function pointOnSegment(point, start, end, epsilon = 0.01) {
  return Math.abs(orientation(start, end, point)) <= epsilon
    && point.x >= Math.min(start.x, end.x) - epsilon
    && point.x <= Math.max(start.x, end.x) + epsilon
    && point.y >= Math.min(start.y, end.y) - epsilon
    && point.y <= Math.max(start.y, end.y) + epsilon
}

function collinearOverlap(a, b, c, d, epsilon = 0.01) {
  if (Math.abs(orientation(a, b, c)) > epsilon || Math.abs(orientation(a, b, d)) > epsilon) return false
  const axis = Math.abs(b.x - a.x) >= Math.abs(b.y - a.y) ? "x" : "y"
  const overlap = Math.min(Math.max(a[axis], b[axis]), Math.max(c[axis], d[axis]))
    - Math.max(Math.min(a[axis], b[axis]), Math.min(c[axis], d[axis]))
  return overlap > epsilon
}

function routeInteriorsIntersect(a, b, epsilon = 0.01) {
  for (let aIndex = 1; aIndex < a.length; aIndex += 1) {
    for (let bIndex = 1; bIndex < b.length; bIndex += 1) {
      const [aStart, aEnd] = [a[aIndex - 1], a[aIndex]]
      const [bStart, bEnd] = [b[bIndex - 1], b[bIndex]]
      if (properSegmentIntersection(aStart, aEnd, bStart, bEnd, epsilon)) return true
      if (collinearOverlap(aStart, aEnd, bStart, bEnd, epsilon)) return true

      for (const point of [aStart, aEnd, bStart, bEnd]) {
        const isAEndpoint = samePoint(point, a[0], epsilon) || samePoint(point, a.at(-1), epsilon)
        const isBEndpoint = samePoint(point, b[0], epsilon) || samePoint(point, b.at(-1), epsilon)
        if (!isAEndpoint && !isBEndpoint
          && pointOnSegment(point, aStart, aEnd, epsilon)
          && pointOnSegment(point, bStart, bEnd, epsilon)) return true
      }
    }
  }
  return false
}

function segmentCrossesBox(a, b, box, epsilon = 0.5) {
  const inner = {
    left: box.left + epsilon,
    top: box.top + epsilon,
    right: box.right - epsilon,
    bottom: box.bottom - epsilon,
  }
  if (inner.left >= inner.right || inner.top >= inner.bottom) return false
  if (a.x > inner.left && a.x < inner.right && a.y > inner.top && a.y < inner.bottom) return true
  if (b.x > inner.left && b.x < inner.right && b.y > inner.top && b.y < inner.bottom) return true
  const corners = [
    {x: inner.left, y: inner.top},
    {x: inner.right, y: inner.top},
    {x: inner.right, y: inner.bottom},
    {x: inner.left, y: inner.bottom},
  ]
  return corners.some((corner, index) => properSegmentIntersection(a, b, corner, corners[(index + 1) % 4]))
}

function assertScene(snapshot, expected) {
  expect(snapshot.counts).toMatchObject(expected)
  expect(snapshot.glyphs).toHaveLength(expected.renderedGlyphs)
  expect(snapshot.routes).toHaveLength(expected.renderedRoutes)

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
      if ([a.sourceId, a.targetId].some((id) => id === b.sourceId || id === b.targetId)) continue
      expect(routeInteriorsIntersect(a.points, b.points), `${a.id} intersects ${b.id}`).toBe(false)
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
      for (let index = 1; index < route.projectedPoints.length; index += 1) {
        expect(
          segmentCrossesBox(route.projectedPoints[index - 1], route.projectedPoints[index], label.box),
          `${label.nodeId} label hits ${route.id}`,
        ).toBe(false)
      }
    }
  }
  for (const glyph of snapshot.glyphs) {
    expect(inside(glyph, snapshot.safeRect), `${glyph.nodeId} glyph leaves safe rect`).toBe(true)
  }
  for (const route of snapshot.routes) {
    expect(inside(route.box, snapshot.safeRect), `${route.id} route leaves safe rect`).toBe(true)
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

async function phase(page, context, name) {
  const screenshot = resolve(OUTPUT_DIR, `${name}.png`)
  const trace = resolve(OUTPUT_DIR, `${name}.trace.zip`)
  await page.screenshot({path: screenshot, animations: "disabled"})
  await context.tracing.stop({path: trace})
  await context.tracing.start({screenshots: true, snapshots: true, sources: true, title: name})
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
    semanticNodes: 30, semanticEdges: 34, attachmentEdges: 24, renderedRoutes: 32, renderedGlyphs: 30,
  })
  await phase(page, context, "collapsed")

  const expandedResult = await page.evaluate(() => window.__SR_GOD_VIEW_HARNESS__.renderFixture("expanded"))
  expect(expandedResult.snapshot.groups).toHaveLength(1)
  expect(expandedResult.snapshot.groups[0].memberIds).toHaveLength(24)
  assertScene(expandedResult.snapshot, {
    semanticNodes: 54, semanticEdges: 58, attachmentEdges: 48, renderedRoutes: 32, renderedGlyphs: 53,
  })
  await phase(page, context, "expanded")

  const firstFit = await page.evaluate(() => window.__SR_GOD_VIEW_HARNESS__.fit())
  const secondFit = await page.evaluate(() => window.__SR_GOD_VIEW_HARNESS__.fit())
  expect(secondFit.viewState).toEqual(firstFit.viewState)
  expect(secondFit.glyphs).toEqual(firstFit.glyphs)
  expect(secondFit.labels).toEqual(firstFit.labels)
  await phase(page, context, "fit")

  const focused = await page.evaluate(() => window.__SR_GOD_VIEW_HARNESS__.focus())
  expect(focused.viewState).not.toEqual(secondFit.viewState)

  const concurrentResult = await page.evaluate(() => window.__SR_GOD_VIEW_HARNESS__.renderFixture("concurrent"))
  expect(concurrentResult.snapshot.groups).toHaveLength(2)
  assertScene(concurrentResult.snapshot, {
    semanticNodes: 78, semanticEdges: 82, attachmentEdges: 72, renderedRoutes: 32, renderedGlyphs: 76,
  })
  const concurrentGeometry = stableGeometry(concurrentResult.snapshot)
  await phase(page, context, "concurrent-expanded")

  await page.evaluate(() => window.__SR_GOD_VIEW_HARNESS__.renderFixture("second"))
  const reexpanded = await page.evaluate(() => window.__SR_GOD_VIEW_HARNESS__.renderFixture("concurrent"))
  expect(stableGeometry(reexpanded.snapshot)).toEqual(concurrentGeometry)

  const portrait = await page.evaluate(() => window.__SR_GOD_VIEW_HARNESS__.profile(800, 1000))
  expect(portrait.profileKey).not.toEqual(concurrentResult.snapshot.profileKey)
  expect(portrait.profileKey).toMatch(/portrait/)
  await context.tracing.stop({path: resolve(OUTPUT_DIR, "profile-threshold.trace.zip")})
})
