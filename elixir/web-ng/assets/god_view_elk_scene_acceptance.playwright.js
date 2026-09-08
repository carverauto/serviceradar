import {expect, test} from "@playwright/test"
import {mkdir} from "node:fs/promises"
import {resolve} from "node:path"

import {createAcceptanceTimeline} from "./god_view_acceptance_timeline.js"
import {
  groupGeometryViolations,
  routeInsideSafeRect,
  routeInteriorsIntersect,
  routeStrokesOverlap,
  routeStrokeHitsBox,
  segmentAabbDistance,
  transportLayerRouteIdViolations,
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

function routeDescription(route) {
  return `${route.sourceId} -> ${route.targetId}`
}

function assertProjectedGlyphsDisjoint(snapshot, phase) {
  for (let left = 0; left < snapshot.glyphs.length; left += 1) {
    for (let right = left + 1; right < snapshot.glyphs.length; right += 1) {
      const first = snapshot.glyphs[left]
      const second = snapshot.glyphs[right]
      expect(
        overlaps(first, second),
        `${phase}: projected glyph ${first.nodeId} overlaps ${second.nodeId}`,
      ).toBe(false)
    }
  }
}

function assertFocusedNeighborhood(snapshot, {anchorId, memberPrefix}) {
  assertProjectedGlyphsDisjoint(snapshot, "focus")
  // The radial atlas frames a cluster by membership, not by a compound group rectangle, so the
  // contract is asserted against the drawn glyphs themselves. The manifold/auxiliary-path
  // assertions that used to live here went with the bounded-detail scene, which is the only
  // layout that ever produced them.
  const memberIds = snapshot.glyphIds.filter((id) => id.startsWith(memberPrefix))
  expect(memberIds.length, `${anchorId} must retain its member glyphs`).toBeGreaterThan(0)

  const selectedIds = new Set([anchorId, ...memberIds])
  const semanticRoutes = snapshot.routes.filter((route) => route.auxiliary !== true
    && (selectedIds.has(route.sourceId) || selectedIds.has(route.targetId)))
  expect(semanticRoutes.length, `${anchorId} focused semantic routes are missing`).toBeGreaterThan(0)
  const semanticRouteIds = new Set(semanticRoutes.map((route) => route.id))
  const focusedRoutes = snapshot.routes.filter((route) => semanticRouteIds.has(route.id)
    || route.semanticRouteIds.some((routeId) => semanticRouteIds.has(routeId)))
  const focusedNodeIds = new Set(selectedIds)
  for (const route of semanticRoutes) {
    focusedNodeIds.add(route.sourceId)
    focusedNodeIds.add(route.targetId)
  }

  const selectedGlyphs = snapshot.glyphs.filter((glyph) => focusedNodeIds.has(glyph.nodeId))
  const glyphIds = new Set(selectedGlyphs.map((glyph) => glyph.nodeId))
  for (const nodeId of [anchorId, ...memberIds]) {
    expect(glyphIds.has(nodeId), `${anchorId} focused glyph ${nodeId} is missing`).toBe(true)
  }
  for (const glyph of selectedGlyphs) {
    expect(inside(glyph, snapshot.safeRect), `${glyph.nodeId} focused glyph leaves safe rect`).toBe(true)
  }

  for (const route of focusedRoutes) {
    expect(routeInsideSafeRect(route, snapshot.safeRect), `${routeDescription(route)} focused route leaves safe rect`).toBe(true)
    for (const glyph of selectedGlyphs) {
      if (glyph.nodeId === route.sourceId || glyph.nodeId === route.targetId) continue
      expect(
        routeStrokeHitsBox(route, glyph),
        `${routeDescription(route)} focused route hits ${glyph.nodeId}`,
      ).toBe(false)
    }
  }
  for (let left = 0; left < focusedRoutes.length; left += 1) {
    for (let right = left + 1; right < focusedRoutes.length; right += 1) {
      const first = focusedRoutes[left]
      const second = focusedRoutes[right]
      expect(
        routeInteriorsIntersect(first, second),
        `${routeDescription(first)} focused route intersects ${routeDescription(second)}`,
      ).toBe(false)
      expect(
        routeStrokesOverlap(first, second),
        `${routeDescription(first)} focused stroke overlaps ${routeDescription(second)}`,
      ).toBe(false)
    }
  }

  const selectedLabels = snapshot.labels.filter((label) => focusedNodeIds.has(label.nodeId))
  expect(selectedLabels.length, `${anchorId} must retain admitted neighborhood labels`).toBeGreaterThan(0)
  for (let left = 0; left < selectedLabels.length; left += 1) {
    const label = selectedLabels[left]
    expect(inside(label.box, snapshot.safeRect), `${label.nodeId} focused label leaves safe rect`).toBe(true)
    for (let right = left + 1; right < selectedLabels.length; right += 1) {
      expect(
        overlaps(label.box, selectedLabels[right].box),
        `${label.nodeId} focused label collision`,
      ).toBe(false)
    }
    for (const glyph of selectedGlyphs) {
      if (glyph.nodeId === label.nodeId) continue
      expect(overlaps(label.box, glyph), `${label.nodeId} focused label hits ${glyph.nodeId}`).toBe(false)
    }
    for (const route of focusedRoutes) {
      expect(
        routeStrokeHitsBox(route, label.box),
        `${label.nodeId} focused label hits ${routeDescription(route)}`,
      ).toBe(false)
    }
  }
}

// Expanding elaborates the radial atlas in place, so there is no compound group to inspect --
// this replaces the group assertions that outlived the bounded-detail contract. What has to
// hold instead is that an opened cluster stays tied into the backbone: the summary bubble it
// replaced is no longer drawn, and every member's rendered route lands on the anchor glyph,
// which is. Members left parented on the hidden summary is the "island" regression -- the ring
// renders, but each route terminates on a glyph that is never drawn, so nothing visibly
// connects the opened cluster to the rest of the graph.
function assertClusterElaborated(snapshot, expansions) {
  const drawn = new Set(snapshot.glyphIds)
  for (const {anchorId, summaryId, memberPrefix, count} of expansions) {
    expect(drawn.has(summaryId), `${summaryId} must not be drawn once expanded`).toBe(false)
    expect(drawn.has(anchorId), `${anchorId} must be drawn as its members' attachment`).toBe(true)

    const memberIds = snapshot.glyphIds.filter((id) => id.startsWith(memberPrefix)).sort()
    expect(memberIds, `${memberPrefix}* members must be drawn`).toHaveLength(count)

    const counterparts = new Map()
    for (const route of snapshot.routes) {
      if (route.auxiliary === true) continue
      const sourceId = String(route.sourceId)
      const targetId = String(route.targetId)
      if (sourceId.startsWith(memberPrefix)) counterparts.set(sourceId, targetId)
      if (targetId.startsWith(memberPrefix)) counterparts.set(targetId, sourceId)
    }
    expect(
      [...counterparts.keys()].sort(),
      `every ${memberPrefix}* member needs a rendered route`,
    ).toEqual(memberIds)
    for (const [memberId, counterpartId] of counterparts) {
      expect(counterpartId, `${memberId} must attach to ${anchorId}`).toBe(anchorId)
    }
  }
}

function assertScene(snapshot, expected) {
  expect(snapshot.counts).toEqual(expected)
  expect(snapshot.glyphs).toHaveLength(expected.renderedGlyphs)
  expect(snapshot.routes.filter((route) => route.auxiliary !== true)).toHaveLength(expected.renderedRoutes)
  expect(snapshot.routes).toHaveLength(expected.renderedPhysicalRoutes)
  expect(new Set(snapshot.routes.map((route) => route.id)).size).toBe(expected.physicalRoutes)
  expect(snapshot.scenePhysicalRouteIds).toHaveLength(expected.physicalRoutes)
  expect(new Set(snapshot.scenePhysicalRouteIds).size).toBe(expected.physicalRoutes)
  expect(
    transportLayerRouteIdViolations(snapshot),
    "each enabled mantle/crust layer family must render every ELK physical route exactly once",
  ).toEqual([])
  expect(snapshot.labels).toHaveLength(snapshot.counts.admittedLabels)
  expect(groupGeometryViolations(snapshot)).toEqual([])
  assertProjectedGlyphsDisjoint(snapshot, snapshot.sceneKey || "scene")
  for (const route of snapshot.routes) {
    expect(
      Number.isFinite(route.strokeWidth) && route.strokeWidth > 0,
      `${routeDescription(route)} must expose a finite positive rendered stroke width`,
    ).toBe(true)
    expect(route.points, `${route.id} rendered path differs from its ELK scene path`).toEqual(route.scenePoints)
    expect(route.layerPaths.length, `${route.id} is absent from every rendered PathLayer`).toBeGreaterThan(0)
    for (const layerPath of route.layerPaths) {
      expect(
        layerPath.points,
        `${route.id} differs in rendered layer ${layerPath.layerId}`,
      ).toEqual(route.scenePoints)
    }
  }

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
      expect(routeInteriorsIntersect(a, b), `${routeDescription(a)} intersects ${routeDescription(b)}`).toBe(false)
      expect(routeStrokesOverlap(a, b), `${routeDescription(a)} stroke overlaps ${routeDescription(b)}`).toBe(false)
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
      expect(routeStrokeHitsBox(route, label.box), `${label.nodeId} label hits ${routeDescription(route)}`).toBe(false)
    }
  }
  for (const glyph of snapshot.glyphs) {
    expect(
      inside(glyph, snapshot.safeRect),
      `${glyph.nodeId} glyph leaves safe rect [nodes=${snapshot.counts.semanticNodes} ` +
      `glyphs=${snapshot.counts.renderedGlyphs} box=${Math.round(glyph.left)},${Math.round(glyph.top)},` +
      `${Math.round(glyph.right)},${Math.round(glyph.bottom)} safe=${Math.round(snapshot.safeRect.left)},` +
      `${Math.round(snapshot.safeRect.top)},${Math.round(snapshot.safeRect.right)},${Math.round(snapshot.safeRect.bottom)} ` +
      `zoom=${snapshot.viewState.zoom.toFixed(4)} minZoom=${snapshot.viewState.minZoom.toFixed(4)}]`,
    ).toBe(true)
  }
  for (const route of snapshot.routes) {
    expect(routeInsideSafeRect(route, snapshot.safeRect), `${routeDescription(route)} route leaves safe rect`).toBe(true)
    for (const glyph of snapshot.glyphs) {
      if (glyph.nodeId === route.sourceId || glyph.nodeId === route.targetId) continue
      const distances = route.projectedPoints.slice(1).map((point, index) =>
        segmentAabbDistance(route.projectedPoints[index], point, glyph))
      const clearance = Math.min(...distances) - (route.strokeWidth / 2)
      expect(
        routeStrokeHitsBox(route, glyph),
        `${routeDescription(route)} hits nonincident glyph ${glyph.nodeId}; stroke=${route.strokeWidth}; clearance=${clearance}; glyph=${JSON.stringify(glyph)}`,
      ).toBe(false)
    }
    for (const group of snapshot.groups) {
      const incidentNodeIds = new Set([group.gatewayId, ...group.memberIds])
      if (incidentNodeIds.has(route.sourceId) || incidentNodeIds.has(route.targetId)) continue
      expect(
        routeStrokeHitsBox(route, group.projectedBox),
        `${routeDescription(route)} hits nonincident group ${group.id}`,
      ).toBe(false)
    }
  }
}

function stableGeometry(snapshot) {
  return {
    profileKey: snapshot.profileKey,
    counts: snapshot.counts,
    nodes: snapshot.nodes,
    groups: snapshot.groups.map(({projectedBox: _projected, ...group}) => group),
    routes: snapshot.routes.map(({projectedPoints: _projected, ...route}) => ({
      ...route,
      junctions: route.junctions.map(({projectedPoint: _junctionProjection, ...junction}) => junction),
    })),
  }
}

function stableGroups(snapshot) {
  return snapshot.groups.map(({projectedBox: _projected, ...group}) => group)
}

function assertConcurrentScene(snapshot) {
  assertClusterElaborated(snapshot, [
    {anchorId: "farm01:gateway-01", summaryId: "farm01:endpoint-summary-01", memberPrefix: "farm01:endpoint-member-01-", count: 24},
    {anchorId: "farm01:gateway-02", summaryId: "farm01:endpoint-summary-02", memberPrefix: "farm01:endpoint-member-02-", count: 24},
  ])
  assertScene(snapshot, {
    semanticNodes: 58, semanticEdges: 60, attachmentEdges: 0, renderedRoutes: 57,
    physicalRoutes: 57, renderedPhysicalRoutes: 57, manifolds: 0, renderedGlyphs: 58, admittedLabels: 49,
  })
}

async function runStep(measure, name, operation, describeResult) {
  return test.step(name, () => measure(name, operation, describeResult))
}

async function preparePage(page, measure) {
  await runStep(measure, "install fixture DOM", () => page.setContent(`<!doctype html>
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
    <div id="god-view-fixture"></div>`))
  await runStep(measure, "load production renderer bundle", () => page.addScriptTag({path: BUNDLE}))
  await runStep(measure, "wait for acceptance harness", () => page.waitForFunction(() => window.__SR_GOD_VIEW_HARNESS__))
  await runStep(measure, "wait for document fonts", () => page.evaluate(() => document.fonts.ready))
}

async function renderFixture(page, measure, fixture, step = `render ${fixture}`) {
  return runStep(
    measure,
    step,
    () => page.evaluate((name) => window.__SR_GOD_VIEW_HARNESS__.renderFixture(name), fixture),
    ({elapsedMs}) => ({rendererElapsedMs: Math.round(elapsedMs * 100) / 100}),
  )
}

async function capturePhase(page, measure, name) {
  await runStep(measure, `capture ${name} screenshot`, () => page.screenshot({
    path: resolve(OUTPUT_DIR, `${name}.png`),
    animations: "disabled",
  }))
}

function timeline(name) {
  return createAcceptanceTimeline({path: resolve(OUTPUT_DIR, `${name}.timings.jsonl`)})
}

test("gates collapsed, expanded, fit, focus, and concurrent roundtrip geometry", async ({page}) => {
  await mkdir(OUTPUT_DIR, {recursive: true})
  const measure = timeline("layout-focus")
  await preparePage(page, measure)

  const collapsedResult = await renderFixture(page, measure, "collapsed")
  await runStep(measure, "assert collapsed geometry", () => {
    assertScene(collapsedResult.snapshot, {
      semanticNodes: 12, semanticEdges: 14, attachmentEdges: 0, renderedRoutes: 11,
      physicalRoutes: 11, renderedPhysicalRoutes: 11, manifolds: 0, renderedGlyphs: 12, admittedLabels: 12,
    })
  })
  await capturePhase(page, measure, "collapsed")

  const expandedResult = await renderFixture(page, measure, "expanded")
  await runStep(measure, "assert expanded geometry", () => {
    assertClusterElaborated(expandedResult.snapshot, [
      {anchorId: "farm01:gateway-01", summaryId: "farm01:endpoint-summary-01", memberPrefix: "farm01:endpoint-member-", count: 24},
    ])
    assertScene(expandedResult.snapshot, {
      semanticNodes: 35, semanticEdges: 37, attachmentEdges: 0, renderedRoutes: 34,
      physicalRoutes: 34, renderedPhysicalRoutes: 34, manifolds: 0, renderedGlyphs: 35, admittedLabels: 33,
    })
  })
  await capturePhase(page, measure, "expanded")

  const firstFit = await runStep(measure, "run first managed fit", () => (
    page.evaluate(() => window.__SR_GOD_VIEW_HARNESS__.fit())
  ))
  const secondFit = await runStep(measure, "run second managed fit", () => (
    page.evaluate(() => window.__SR_GOD_VIEW_HARNESS__.fit())
  ))
  await runStep(measure, "assert managed fit idempotence", () => {
    expect(secondFit.viewState).toEqual(firstFit.viewState)
    expect(secondFit.glyphs).toEqual(firstFit.glyphs)
    expect(secondFit.labels).toEqual(firstFit.labels)
    assertProjectedGlyphsDisjoint(firstFit, "first Fit")
    assertProjectedGlyphsDisjoint(secondFit, "second Fit")
  })
  await capturePhase(page, measure, "fit")

  const focused = await runStep(measure, "focus gateway neighborhood", () => (
    page.evaluate(() => window.__SR_GOD_VIEW_HARNESS__.focus())
  ))
  await runStep(measure, "assert focused geometry", () => {
    expect(focused.viewState).not.toEqual(secondFit.viewState)
    expect(stableGroups(focused)).toEqual(stableGroups(expandedResult.snapshot))
    expect(focused.nodes).toEqual(expandedResult.snapshot.nodes)
    expect(stableGeometry(focused).routes).toEqual(stableGeometry(expandedResult.snapshot).routes)
    assertFocusedNeighborhood(focused, {anchorId: "farm01:gateway-01", memberPrefix: "farm01:endpoint-member-"})
  })

  const concurrentAfterFocus = await renderFixture(
    page,
    measure,
    "concurrent",
    "render concurrent after focus",
  )
  const concurrentGeometry = await runStep(measure, "assert concurrent geometry after focus", () => {
    assertConcurrentScene(concurrentAfterFocus.snapshot)
    return stableGeometry(concurrentAfterFocus.snapshot)
  })
  await capturePhase(page, measure, "concurrent-after-focus")

  const firstCollapsed = await renderFixture(page, measure, "second")
  await runStep(measure, "assert second cluster geometry", () => {
    assertClusterElaborated(firstCollapsed.snapshot, [
      {anchorId: "farm01:gateway-02", summaryId: "farm01:endpoint-summary-02", memberPrefix: "farm01:endpoint-member-02-", count: 24},
    ])
    assertScene(firstCollapsed.snapshot, {
      semanticNodes: 35, semanticEdges: 37, attachmentEdges: 0, renderedRoutes: 34,
      physicalRoutes: 34, renderedPhysicalRoutes: 34, manifolds: 0, renderedGlyphs: 35, admittedLabels: 33,
    })
  })

  const reexpanded = await renderFixture(page, measure, "concurrent", "render concurrent roundtrip")
  await runStep(measure, "assert concurrent roundtrip geometry", () => {
    expect(stableGeometry(reexpanded.snapshot)).toEqual(concurrentGeometry)
    assertScene(reexpanded.snapshot, {
      semanticNodes: 58, semanticEdges: 60, attachmentEdges: 0, renderedRoutes: 57,
      physicalRoutes: 57, renderedPhysicalRoutes: 57, manifolds: 0, renderedGlyphs: 58, admittedLabels: 49,
    })
  })
})

test("gates concurrent portrait geometry", async ({page}) => {
  await mkdir(OUTPUT_DIR, {recursive: true})
  const measure = timeline("portrait-profile")
  await preparePage(page, measure)

  const concurrentResult = await renderFixture(page, measure, "concurrent")
  await runStep(measure, "assert concurrent geometry", () => {
    assertConcurrentScene(concurrentResult.snapshot)
  })
  await capturePhase(page, measure, "concurrent-expanded")

  const portrait = await runStep(measure, "render portrait profile", () => (
    page.evaluate(() => window.__SR_GOD_VIEW_HARNESS__.profile(800, 1000))
  ))
  await runStep(measure, "assert portrait geometry", () => {
    // The radial atlas reports a constant profileKey -- per-viewport density profiles were a
    // bounded-detail concept -- so assert what portrait actually changes: the same scene is still
    // laid out in full, and the narrower viewport admits no more labels than the wide one did.
    expect(portrait.counts.semanticNodes).toEqual(concurrentResult.snapshot.counts.semanticNodes)
    expect(portrait.counts.admittedLabels).toBeLessThanOrEqual(concurrentResult.snapshot.counts.admittedLabels)
    // admittedLabels rose from 17 to 28 when resizeCanvas started adopting the new size into
    // Deck's own viewport. Before that, a resized surface projected glyphs through the PREVIOUS
    // viewport while clipping labels to the new safe rect, so labels were rejected for leaving a
    // rect their glyph had never actually left. 28 of 58 admitted, against 49 at 1920x1080.
    assertScene(portrait, {
      semanticNodes: 58, semanticEdges: 60, attachmentEdges: 0, renderedRoutes: 57,
      physicalRoutes: 57, renderedPhysicalRoutes: 57, manifolds: 0, renderedGlyphs: 58, admittedLabels: 28,
    })
  })
})
