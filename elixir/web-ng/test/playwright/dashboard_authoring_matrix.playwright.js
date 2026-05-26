async (page) => {
  const baseUrl = "http://localhost:4000"
  const env = globalThis.process?.env || {}
  const email = env.PLAYWRIGHT_AUTH_EMAIL
  const password = env.PLAYWRIGHT_AUTH_PASSWORD

  if (!email || !password) {
    throw new Error("Set PLAYWRIGHT_AUTH_EMAIL and PLAYWRIGHT_AUTH_PASSWORD before running this matrix.")
  }

  const cases = [
    {name: "service rows", query: "in:services time:last_1h sort:timestamp:desc limit:25", absent: ["availability"]},
    {name: "service availability rollup", query: "in:service_availability time:last_1h rollup_stats:availability", present: ["availability", "gauge"]},
    {name: "http services", query: "in:services service_type:http time:last_24h limit:25", absent: ["availability"]},
    {name: "plugin services", query: "in:services service_type:plugin time:last_24h limit:25", absent: ["availability"]},
    {name: "available devices", query: "in:devices is_available:true limit:25", absent: ["availability"]},
    {name: "unavailable devices", query: "in:devices is_available:false limit:25", absent: ["availability"]},
    {name: "active devices", query: "in:devices is_active:true limit:25", absent: ["availability"]},
    {name: "device type stats", query: "in:devices stats:count() as count by type limit:25", present: ["bar", "category"]},
    {name: "device vendor stats", query: "in:devices stats:count() as count by vendor_name limit:25", present: ["bar", "category"]},
    {name: "device availability stats", query: "in:devices stats:count() as count by is_available limit:25", present: ["bar"]},
    {name: "device vendor type pivot", query: "in:devices stats:count() as count by vendor_name,type limit:25", present: ["pivot"]},
    {name: "device type single dimension", query: "in:devices stats:count() as count by type limit:25", absent: ["pivot"]},
    {name: "agents", query: "in:agents limit:25", absent: ["availability"]},
    {name: "gateways", query: "in:gateways limit:25", absent: ["availability"]},
    {name: "events", query: "in:events time:last_24h sort:timestamp:desc limit:25", absent: ["availability"]},
    {name: "bmp events", query: "in:bmp_events time:last_24h sort:time:desc limit:25", absent: ["availability"]},
    {name: "logs", query: "in:logs time:last_24h sort:timestamp:desc limit:25", absent: ["availability"]},
    {name: "log severity rollup", query: "in:logs time:last_24h rollup_stats:severity", present: ["stat", "gauge", "bar"]},
    {name: "interfaces", query: "in:interfaces limit:25", absent: ["availability"]},
    {name: "interfaces latest", query: "in:interfaces latest:true limit:25", absent: ["availability"]},
    {name: "otel traces", query: "in:otel_traces time:last_24h limit:25", absent: ["availability"]},
    {name: "otel trace summary", query: "in:otel_traces time:last_24h rollup_stats:summary", present: ["stat", "gauge"]},
    {name: "otel metrics", query: "in:otel_metrics time:last_24h limit:25", absent: ["availability"]},
    {name: "otel metric summary", query: "in:otel_metrics time:last_24h rollup_stats:summary", present: ["gauge", "line", "bar"]},
    {name: "wifi sites", query: "in:wifi_sites limit:25", absent: ["availability"]},
    {name: "wifi devices", query: "in:wifi_devices limit:25", absent: ["availability"]},
    {name: "dashboards", query: "in:dashboards sort:title:asc limit:25", absent: ["availability"]},
  ]

  async function ensureLoggedIn(targetPath) {
    await page.goto(`${baseUrl}${targetPath}`, {waitUntil: "domcontentloaded", timeout: 30_000})

    if (page.url().includes("/users/log-in")) {
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

  await ensureLoggedIn("/dashboard/1000001")
  await page.waitForURL(/\/dashboard\/1000001/, {timeout: 15_000})
  await page.getByRole("button", {name: "Settings", exact: true}).click()

  const results = []

  for (const testCase of cases) {
    if (!(await page.locator("#authored-panel-srql-editor-new-input").count())) {
      await page.getByRole("button", {name: "Add Panel"}).click()
      await page.locator("#authored-panel-srql-editor-new-input").waitFor({timeout: 10_000})
    }

    await page.locator("input[name=\"panel[title]\"]").fill(testCase.name)
    await setSrql(testCase.query)
    await page.getByRole("button", {name: "Preview Query"}).click()
    try {
      await page.waitForFunction(() => {
        const cancel = document.querySelector('button[phx-click="cancel_panel_edit"]')
        return cancel && !cancel.disabled
      }, undefined, {timeout: 10_000})
    } catch (error) {
      throw new Error(`${testCase.name}: preview did not settle`)
    }

    const options = await page
      .locator("select[name=\"panel[visual_type]\"] option")
      .evaluateAll((nodes) => nodes.map((node) => node.value))

    for (const visual of testCase.present || []) {
      if (!options.includes(visual)) {
        throw new Error(`${testCase.name}: expected ${visual}, got ${options.join(",")}`)
      }
    }

    for (const visual of testCase.absent || []) {
      if (options.includes(visual)) {
        throw new Error(`${testCase.name}: did not expect ${visual}, got ${options.join(",")}`)
      }
    }

    results.push({name: testCase.name, options})
    await page.getByRole("button", {name: "Cancel"}).click()
  }

  return results
}
