import {expect, test} from "@playwright/test"
import {resolve} from "node:path"

const BUNDLE = resolve(
  process.env.TEST_SRCDIR,
  process.env.TEST_WORKSPACE,
  process.env.CHART_RANGE_SELECTION_ACCEPTANCE_BUNDLE,
)

const EXPECTED_PUSH = {
  kind: "push",
  name: "netflow_range_selected",
  payload: {
    start: "2026-08-29T01:00:00.000000Z",
    end: "2026-08-29T01:01:59.999999Z",
  },
}

test.use({
  viewport: {width: 1280, height: 720},
  deviceScaleFactor: 1,
  channel: "chromium",
})

async function mountFixture(page, renderer) {
  await page.goto("about:blank")
  await page.addScriptTag({path: BUNDLE})
  await page.evaluate((name) => window.chartRangeAcceptance.mount(name), renderer)
}

async function snapshot(page) {
  return page.evaluate(() => window.chartRangeAcceptance.snapshot())
}

async function pushes(page) {
  return (await snapshot(page)).trace.filter((entry) => entry.kind === "push")
}

async function mouseSession(page) {
  return page.context().newCDPSession(page)
}

async function press(session, box, fraction = 0.25) {
  await session.send("Input.dispatchMouseEvent", {
    type: "mousePressed",
    x: box.x + box.width * fraction,
    y: box.y + box.height * 0.5,
    button: "left",
    buttons: 1,
    clickCount: 1,
  })
}

async function move(session, box, fraction = 0.75) {
  await session.send("Input.dispatchMouseEvent", {
    type: "mouseMoved",
    x: box.x + box.width * fraction,
    y: box.y + box.height * 0.5,
    button: "left",
    buttons: 1,
  })
}

async function releaseOutside(session, box) {
  await session.send("Input.dispatchMouseEvent", {
    type: "mouseReleased",
    x: box.x + box.width * 0.75,
    y: box.y + box.height + 8,
    button: "left",
    buttons: 0,
    clickCount: 1,
  })
}

function traceMessage(trace) {
  return `native chart range trace:\n${JSON.stringify(trace, null, 2)}`
}

for (const renderer of ["server-svg", "d3"]) {
  test(`${renderer} first drag survives a compatible node replacement`, async ({page}) => {
    await mountFixture(page, renderer)
    const box = await page.locator('[role="group"]').boundingBox()
    expect(box).not.toBeNull()

    await page.evaluate(() => window.chartRangeAcceptance.replaceRendererNodes())
    const session = await mouseSession(page)
    await press(session, box)
    await page.evaluate(() => window.chartRangeAcceptance.updateHook())
    await releaseOutside(session, box)

    const result = await snapshot(page)
    expect(result.trace.some((entry) => entry.kind === "renderer-replacement")).toBe(true)
    expect(result.trace.some((entry) => entry.kind === "pointer" && entry.type === "pointerdown")).toBe(true)
    expect(await pushes(page), traceMessage(result.trace)).toEqual([EXPECTED_PUSH])
  })

  test(`${renderer} continues a captured drag across a renderer replacement`, async ({page}) => {
    await mountFixture(page, renderer)
    const box = await page.locator('[role="group"]').boundingBox()
    expect(box).not.toBeNull()

    const session = await mouseSession(page)
    await press(session, box)
    await move(session, box)
    await page.evaluate(() => window.chartRangeAcceptance.replaceRendererNodes())
    await page.evaluate(() => window.chartRangeAcceptance.updateHook())
    await releaseOutside(session, box)

    const result = await snapshot(page)
    expect(result.trace.some((entry) => entry.kind === "renderer-replacement")).toBe(true)
    expect(result.trace.some((entry) => entry.kind === "pointer" && entry.rootHasCapture)).toBe(true)
    expect(await pushes(page), traceMessage(result.trace)).toEqual([EXPECTED_PUSH])
  })

  test(`${renderer} preserves a sub-threshold click without emitting a range`, async ({page}) => {
    await mountFixture(page, renderer)
    const box = await page.locator('[role="group"]').boundingBox()
    expect(box).not.toBeNull()

    await page.mouse.click(box.x + box.width * 0.25, box.y + box.height * 0.5)

    const result = await snapshot(page)
    expect(await pushes(page), traceMessage(result.trace)).toEqual([])
    expect(result.trace.filter((entry) => entry.kind === "click")).toHaveLength(1)
  })
}
