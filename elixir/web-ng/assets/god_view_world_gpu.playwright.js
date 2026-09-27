import {expect, test} from "@playwright/test"
import {resolve} from "node:path"

const html = resolve(process.env.TEST_SRCDIR, process.env.TEST_WORKSPACE, process.env.GOD_VIEW_WORLD_GPU_PAGE)

// Real rendering/picking contract. RBE uses WebGPU on SwiftShader; the same
// RBE-built page is also checked on a physical GPU for the performance contract.
for (const deviceScaleFactor of [1, 2]) {
  test.describe(`world tiles at DPR ${deviceScaleFactor}`, () => {
    test.use({viewport: {width: 1280, height: 720}, deviceScaleFactor})

    test("picks visible geometry and retains it across revisit and telemetry", async ({page}) => {
      const errors = []
      page.on("pageerror", error => errors.push(error.message))
      await page.route("http://localhost:4774/", route => route.fulfill({path: html, contentType: "text/html"}))
      await page.goto("http://localhost:4774/")
      await expect(page.locator("#status")).toContainText("GPU smoke: webgpu")
      await expect(page.locator("#status")).toContainText("decoded tiles=4")

      // The canvas starts 100 CSS pixels below the top of the page. The first
      // invented node projects near (368, 129) within that canvas, off-center.
      await page.mouse.click(368, 229)
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
