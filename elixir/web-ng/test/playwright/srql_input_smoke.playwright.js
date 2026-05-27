async (page) => {
  const env = globalThis.process?.env || {}
  const baseUrl = env.PLAYWRIGHT_BASE_URL || "http://localhost:4000"
  const email = env.PLAYWRIGHT_AUTH_EMAIL
  const password = env.PLAYWRIGHT_AUTH_PASSWORD
  const screenshotPath = env.PLAYWRIGHT_SRQL_SCREENSHOT || "tmp/srql-input-idle.png"
  const baseline = {
    viewport: {width: 1280, height: 720},
    input: {
      height: 30,
      heightTolerance: 4,
      fontSize: "12px",
      lineHeight: "16px",
      paddingLeft: "12px",
      paddingRight: "12px",
      borderRadius: "8px",
    },
  }
  const navigationTimeout = Number(env.PLAYWRIGHT_SRQL_NAVIGATION_TIMEOUT_MS || 60_000)

  async function ensureLoggedIn(targetPath) {
    const currentPath = page.url().replace(/^[a-z]+:\/\/[^/]+/i, "").split(/[?#]/)[0]

    if (currentPath !== targetPath) {
      await page.goto(`${baseUrl}${targetPath}`, {waitUntil: "domcontentloaded", timeout: navigationTimeout})
    }

    if (page.url().includes("/users/log-in")) {
      if (!email || !password) {
        throw new Error("Set PLAYWRIGHT_AUTH_EMAIL and PLAYWRIGHT_AUTH_PASSWORD before running this smoke test.")
      }

      await page.getByRole("textbox", {name: "Email"}).fill(email)
      await page.getByRole("textbox", {name: "Password"}).fill(password)
      await page.getByRole("button", {name: "Sign in"}).click()
      await page.waitForURL(`**${targetPath}`, {timeout: navigationTimeout})
    }
  }

  async function setQuery(query) {
    const input = page.locator("#srql-query-bar-editor")
    await input.click()
    await page.keyboard.press("ControlOrMeta+A")
    await page.keyboard.press("Backspace")
    await page.keyboard.type(query)
    return input
  }

  async function primeCatalog() {
    await page.evaluate(async () => {
      window.__srqlCatalog ||= {etag: null, data: null}
      if (!window.__srqlCatalog.data) {
        const response = await fetch("/api/srql/catalog")
        window.__srqlCatalog.etag = response.headers.get("etag")
        window.__srqlCatalog.data = await response.json()
      }
      window.dispatchEvent(new Event("phx:srql:catalog-stale"))
    })
    await page.waitForTimeout(250)
  }

  function expectEqual(actual, expected, label) {
    if (actual !== expected) {
      throw new Error(`${label}: expected ${expected}, got ${actual}`)
    }
  }

  function expectWithin(actual, expected, tolerance, label) {
    if (Math.abs(actual - expected) > tolerance) {
      throw new Error(`${label}: expected ${expected} +/- ${tolerance}, got ${actual}`)
    }
  }

  await page.setViewportSize(baseline.viewport)
  await ensureLoggedIn("/devices")
  await page.waitForSelector("#srql-query-bar-editor", {timeout: 20_000})
  await page.waitForSelector("[data-srql-input-overlay]", {timeout: 10_000})
  await primeCatalog()

  const input = await setQuery("in:dev")
  await page.keyboard.press("ArrowDown")
  await page.keyboard.press("ArrowUp")
  await page.waitForSelector("[data-srql-input-dropdown]:not(.hidden)", {timeout: 10_000})
  await page.keyboard.press("Tab")
  await page.waitForFunction(() => document.querySelector("#srql-query-bar-editor")?.value === "in:devices ")

  await setQuery("in:device")
  await page.waitForFunction(() => {
    const unknown = document.querySelector("[data-srql-input-overlay] .srql-token--unknown")
    return unknown?.textContent === "device"
  })

  await setQuery("in:devices")
  const inputBox = await input.boundingBox()
  if (!inputBox) throw new Error("SRQL input bounding box was unavailable.")
  await page.mouse.click(inputBox.x + 58, inputBox.y + inputBox.height / 2)
  await page.waitForSelector("[data-srql-input-dropdown]:not(.hidden)", {timeout: 10_000})

  const dropdownLabels = await page
    .locator("[data-srql-input-dropdown] .srql-dropdown__item span:first-child")
    .evaluateAll((nodes) => nodes.map((node) => node.textContent?.trim()).filter(Boolean))
  const catalogEntities = await page.evaluate(() => Object.keys(window.__srqlCatalog?.data?.entities || {}))

  if (dropdownLabels.length < 3) {
    throw new Error(`entity dropdown: expected at least 3 entities, got ${dropdownLabels.join(", ")}`)
  }

  for (const entity of catalogEntities.slice(0, 3)) {
    if (!dropdownLabels.includes(entity)) {
      throw new Error(`entity dropdown: expected ${entity}, got ${dropdownLabels.join(", ")}`)
    }
  }

  await page.keyboard.press("Escape")
  await input.evaluate((node) => {
    node.value = "in:devices hostname:srv"
    node.dispatchEvent(new Event("input", {bubbles: true}))
    node.dispatchEvent(new Event("change", {bubbles: true}))
  })
  const fieldBox = await input.boundingBox()
  if (!fieldBox) throw new Error("SRQL field input bounding box was unavailable.")
  await page.mouse.click(fieldBox.x + 95, fieldBox.y + fieldBox.height / 2)
  await page.waitForSelector("[data-srql-input-dropdown]:not(.hidden)", {timeout: 10_000})
  await page.locator("[data-srql-input-dropdown] .srql-dropdown__item").evaluateAll((items) => {
    const item = items.find((node) => node.querySelector("span")?.textContent?.trim() === "ip")
    if (!item) throw new Error("ip field candidate was not visible")
    item.click()
  })
  await page.waitForFunction(() => document.querySelector("#srql-query-bar-editor")?.value === "in:devices ip:srv")

  await input.evaluate((node) => {
    node.value = ""
    node.dispatchEvent(new Event("input", {bubbles: true}))
    node.dispatchEvent(new Event("change", {bubbles: true}))
  })
  await page.waitForFunction(
    () => document.querySelector("[data-srql-input-dropdown]")?.classList.contains("hidden"),
    null,
    {timeout: 10_000}
  )

  const geometry = await input.evaluate((node) => {
    const rect = node.getBoundingClientRect()
    const style = window.getComputedStyle(node)

    return {
      height: rect.height,
      fontSize: style.fontSize,
      lineHeight: style.lineHeight,
      paddingLeft: style.paddingLeft,
      paddingRight: style.paddingRight,
      borderRadius: style.borderRadius,
      monacoCount: document.querySelectorAll(".monaco-editor").length,
      unknownCount: document.querySelectorAll("[data-srql-input-overlay] .srql-token--unknown").length,
      dropdownHidden: document.querySelector("[data-srql-input-dropdown]")?.classList.contains("hidden"),
    }
  })

  expectWithin(
    geometry.height,
    baseline.input.height,
    baseline.input.heightTolerance,
    "idle SRQL input height"
  )
  expectEqual(geometry.fontSize, baseline.input.fontSize, "idle SRQL input font size")
  expectEqual(geometry.lineHeight, baseline.input.lineHeight, "idle SRQL input line height")
  expectEqual(geometry.paddingLeft, baseline.input.paddingLeft, "idle SRQL input left padding")
  expectEqual(geometry.paddingRight, baseline.input.paddingRight, "idle SRQL input right padding")
  expectEqual(geometry.borderRadius, baseline.input.borderRadius, "idle SRQL input border radius")
  expectEqual(geometry.monacoCount, 0, "compact SRQL input Monaco editor count")
  expectEqual(geometry.unknownCount, 0, "idle SRQL input unknown token count")
  expectEqual(geometry.dropdownHidden, true, "idle SRQL input dropdown hidden state")

  await page.screenshot({path: screenshotPath, fullPage: false})

  return {
    autocomplete: "in:devices ",
    unknownToken: "device",
    fieldReplacement: "in:devices ip:srv",
    entityDropdown: dropdownLabels,
    geometry,
    screenshotPath,
  }
}
