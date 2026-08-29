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
    if (renderer === "d3") {
      const path = page.locator('[data-netflow-stacked-render-root] > g:nth-of-type(3) path')
      await expect(path).toHaveCount(1)
      await path.click()
    } else {
      const bucket = page.locator('[phx-click="netflow_bucket"]')
      await expect(bucket).toHaveAttribute("phx-value-start", "2026-08-29T01:00:00.000000Z")
      await expect(bucket).toHaveAttribute("phx-value-end", "2026-08-29T01:00:59.999999Z")
      await bucket.click()
    }

    const result = await snapshot(page)
    const rangePushes = (await pushes(page)).filter((entry) => entry.name === "netflow_range_selected")
    expect(rangePushes, traceMessage(result.trace)).toEqual([])

    if (renderer === "d3") {
      expect(await pushes(page), traceMessage(result.trace)).toEqual([
        {kind: "push", name: "netflow_stack_series", payload: {field: "app", value: "traffic"}},
      ])
    } else {
      expect(result.trace.filter((entry) => entry.kind === "server-bucket-click")).toEqual([
        {
          kind: "server-bucket-click",
          event: "netflow_bucket",
          start: "2026-08-29T01:00:00.000000Z",
          end: "2026-08-29T01:00:59.999999Z",
          target: "server-bucket",
          currentTarget: "#document",
        },
      ])
    }
  })
}

test("server action trace requires native bubbling to reach document", async ({page}) => {
  await mountFixture(page, "server-svg")
  await page.evaluate(() => {
    document.querySelector('[role="group"]').addEventListener("click", (event) => event.stopPropagation())
  })

  const bucket = page.locator('[phx-click="netflow_bucket"]')
  await bucket.click()

  const result = await snapshot(page)
  expect(result.trace.filter((entry) => entry.kind === "server-bucket-click"), traceMessage(result.trace)).toEqual([])
})
