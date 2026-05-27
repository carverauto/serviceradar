async (page) => {
  const env = globalThis.process?.env || {}
  const baseUrl = env.PLAYWRIGHT_BASE_URL || "http://localhost:4000"
  const email = env.PLAYWRIGHT_AUTH_EMAIL
  const password = env.PLAYWRIGHT_AUTH_PASSWORD
  const currentPath = page.url().replace(/^[a-z]+:\/\/[^/]+/i, "").split(/[?#]/)[0]
  const dashboardPath =
    env.PLAYWRIGHT_DASHBOARD_PATH ||
    (currentPath.startsWith("/dashboard/") ? currentPath : "/dashboard/1000001")

  const cases = [
    {name: "service rows", query: "in:services time:last_1h sort:timestamp:desc limit:25", absent: ["availability", "gauge"]},
    {name: "service availability rollup", query: "in:service_availability time:last_1h rollup_stats:availability", present: ["availability", "gauge"]},
    {name: "http services", query: "in:services service_type:http time:last_24h limit:25", absent: ["availability", "gauge"]},
    {name: "plugin services", query: "in:services service_type:plugin time:last_24h limit:25", absent: ["availability", "gauge"]},
    {name: "available devices", query: "in:devices is_available:true limit:25", absent: ["availability", "gauge"]},
    {name: "unavailable devices", query: "in:devices is_available:false limit:25", absent: ["availability", "gauge"]},
    {name: "active devices", query: "in:devices is_active:true limit:25", absent: ["availability", "gauge"]},
    {name: "device type stats", query: "in:devices stats:count() as count by type limit:25", present: ["bar", "category"], absent: ["availability", "gauge", "pivot"]},
    {name: "device vendor stats", query: "in:devices stats:count() as count by vendor_name limit:25", present: ["bar", "category"], absent: ["availability", "gauge", "pivot"]},
    {name: "device availability stats", query: "in:devices stats:count() as count by is_available limit:25", present: ["availability", "gauge", "bar"]},
    {name: "device vendor type pivot", query: "in:devices stats:count() as count by vendor_name,type limit:25", present: ["pivot"], absent: ["availability", "gauge"]},
    {name: "device type single dimension", query: "in:devices stats:count() as count by type limit:25", absent: ["gauge", "pivot"]},
    {name: "agents", query: "in:agents limit:25", absent: ["availability", "gauge"]},
    {name: "gateways", query: "in:gateways limit:25", absent: ["availability", "gauge"]},
    {name: "events", query: "in:events time:last_24h sort:timestamp:desc limit:25", absent: ["availability", "gauge"]},
    {name: "bmp events", query: "in:bmp_events time:last_24h sort:time:desc limit:25", absent: ["availability", "gauge"]},
    {name: "logs", query: "in:logs time:last_24h sort:timestamp:desc limit:25", absent: ["availability", "gauge"]},
    {name: "log severity rollup", query: "in:logs time:last_24h rollup_stats:severity", present: ["stat", "gauge", "bar"]},
    {name: "interfaces", query: "in:interfaces limit:25", absent: ["availability", "gauge"]},
    {name: "interfaces latest", query: "in:interfaces latest:true limit:25", absent: ["availability", "gauge"]},
    {name: "otel traces", query: "in:otel_traces time:last_24h limit:25", absent: ["availability", "gauge"]},
    {name: "otel trace summary", query: "in:otel_traces time:last_24h rollup_stats:summary", present: ["stat", "gauge"]},
    {name: "otel metrics", query: "in:otel_metrics time:last_24h limit:25", absent: ["availability", "gauge"]},
    {name: "otel metric summary", query: "in:otel_metrics time:last_24h rollup_stats:summary", present: ["line", "bar"], absent: ["availability", "gauge"]},
    {name: "wifi sites", query: "in:wifi_sites limit:25", absent: ["availability", "gauge"]},
    {name: "wifi access points", query: "in:wifi_aps limit:25", absent: ["availability", "gauge"]},
  ]

  async function ensureLoggedIn(targetPath) {
    await page.goto(`${baseUrl}${targetPath}`, {waitUntil: "domcontentloaded", timeout: 30_000})

    if (page.url().includes("/users/log-in")) {
      if (!email || !password) {
        throw new Error("Set PLAYWRIGHT_AUTH_EMAIL and PLAYWRIGHT_AUTH_PASSWORD before running this matrix.")
      }

      await page.getByRole("textbox", {name: "Email"}).fill(email)
      await page.getByRole("textbox", {name: "Password"}).fill(password)
      await page.getByRole("button", {name: "Sign in"}).click()
      await page.waitForURL(`**${targetPath}`, {timeout: 30_000})
    }
  }

  async function setSrql(query) {
    await page.locator("#authored-panel-srql-editor-new-input").evaluate((input, value) => {
      input.value = value
      input.dispatchEvent(new Event("input", {bubbles: true}))
      input.dispatchEvent(new Event("change", {bubbles: true}))
    }, query)
  }

  await ensureLoggedIn(dashboardPath)
  await page.waitForURL(`**${dashboardPath}`, {timeout: 15_000})
  await page.getByRole("button", {name: "Settings", exact: true}).click()
  await page.waitForTimeout(2500)

  const results = []

  for (const testCase of cases) {
    const expectedPresent = [...new Set(["table", ...(testCase.present || [])])]
    const expectedAbsent = testCase.absent || []
    const previewButton = page.locator('button[name="intent"][value="preview"]')

    if (!(await previewButton.count())) {
      await page.getByRole("button", {name: "Add Panel"}).click()
      await previewButton.waitFor({timeout: 10_000})
    }

    await page.locator("input[name=\"panel[title]\"]").fill(testCase.name)
    await setSrql(testCase.query)
    await page.waitForTimeout(200)
    await previewButton.click({force: true, timeout: 10_000})
    try {
      await page.waitForFunction(({present, absent}) => {
        const options = [...document.querySelectorAll('select[name="panel[visual_type]"] option')]
          .map((node) => node.value)

        return present.every((visual) => options.includes(visual)) &&
          absent.every((visual) => !options.includes(visual))
      }, {present: expectedPresent, absent: expectedAbsent}, {timeout: 15_000})
    } catch (error) {
      throw new Error(`${testCase.name}: preview did not settle`)
    }

    const options = await page
      .locator("select[name=\"panel[visual_type]\"] option")
      .evaluateAll((nodes) => nodes.map((node) => node.value))

    for (const visual of expectedPresent) {
      if (!options.includes(visual)) {
        throw new Error(`${testCase.name}: expected ${visual}, got ${options.join(",")}`)
      }
    }

    for (const visual of expectedAbsent) {
      if (options.includes(visual)) {
        throw new Error(`${testCase.name}: did not expect ${visual}, got ${options.join(",")}`)
      }
    }

    results.push({name: testCase.name, options})
    const cancelButton = page.getByRole("button", {name: "Cancel"})
    if (await cancelButton.count()) {
      await cancelButton.click()
      await previewButton.waitFor({state: "detached", timeout: 10_000}).catch(() => {})
    }
  }

  return results
}
