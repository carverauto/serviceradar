async (page) => {
  // Agent badge consistency check (OpenSpec refactor-device-identity-reconciliation, task 7.3).
  //
  // Loads the /devices list, collects every row carrying the agent bolt badge
  // (derived from the platform.ocsf_agents device_uid linkage), then opens each
  // badged device's detail page and asserts the header Agent pill
  // ([data-testid="device-agent-pill"]) renders. Emits a count summary.
  //
  // Env knobs:
  //   PLAYWRIGHT_BASE_URL                 (default http://localhost:4000)
  //   PLAYWRIGHT_AUTH_EMAIL / PLAYWRIGHT_AUTH_PASSWORD
  //   PLAYWRIGHT_DEVICES_PATH             (default: /devices sorted by last_seen desc, limit 100 —
  //                                        connected agents heartbeat constantly, so they surface first)
  //   PLAYWRIGHT_AGENT_BADGE_MAX_DETAILS  (default 50; caps detail-page visits)
  //   PLAYWRIGHT_ALLOW_ZERO_BADGES        (set to "1" to tolerate an empty badge set)
  const env = globalThis.process?.env || {}
  const baseUrl = env.PLAYWRIGHT_BASE_URL || "http://localhost:4000"
  const email = env.PLAYWRIGHT_AUTH_EMAIL
  const password = env.PLAYWRIGHT_AUTH_PASSWORD
  const devicesPath =
    env.PLAYWRIGHT_DEVICES_PATH ||
    `/devices?q=${encodeURIComponent("in:devices sort:last_seen:desc limit:100")}`
  const maxDetailChecks = Number.parseInt(env.PLAYWRIGHT_AGENT_BADGE_MAX_DETAILS || "50", 10)
  const allowZeroBadges = env.PLAYWRIGHT_ALLOW_ZERO_BADGES === "1"

  // Main devices table (the CSV import modal also contains tables when open).
  const deviceRowSelector = "table.table-zebra tbody tr"
  const listBadgeSelector = 'span.hero-bolt[title="Agent device"]'
  const headerPillSelector = '[data-testid="device-agent-pill"]'

  async function ensureLoggedIn(targetPath) {
    await page.goto(`${baseUrl}${targetPath}`, {waitUntil: "domcontentloaded", timeout: 30_000})

    if (page.url().includes("/users/log-in")) {
      if (!email || !password) {
        throw new Error("Set PLAYWRIGHT_AUTH_EMAIL and PLAYWRIGHT_AUTH_PASSWORD before running this check.")
      }

      await page.getByRole("textbox", {name: "Email"}).fill(email)
      await page.getByRole("textbox", {name: "Password"}).fill(password)
      await page.getByRole("button", {name: "Sign in"}).click()
      await page.waitForURL(`**${targetPath.split("?")[0]}**`, {timeout: 30_000})
    }
  }

  await ensureLoggedIn(devicesPath)
  await page.waitForSelector(deviceRowSelector, {timeout: 30_000})
  // Give the LiveView a beat to stream in the enrichment pass that paints badges.
  await page.waitForTimeout(2_000)

  const rows = page.locator(deviceRowSelector)
  const scannedRows = await rows.count()
  const badgedDevices = []

  for (let i = 0; i < scannedRows; i++) {
    const row = rows.nth(i)

    if (!(await row.locator(listBadgeSelector).count())) {
      continue
    }

    const link = row.locator('a[href^="/devices/"]').first()

    if (!(await link.count())) {
      throw new Error(`badged row ${i} has no device link`)
    }

    const href = await link.getAttribute("href")
    const label = ((await link.textContent()) || "").trim()
    badgedDevices.push({href, label})
  }

  if (badgedDevices.length === 0 && !allowZeroBadges) {
    throw new Error(
      `no agent-badged rows found among ${scannedRows} device rows — either no agents are connected ` +
        "(set PLAYWRIGHT_ALLOW_ZERO_BADGES=1 if expected) or the list badge predicate regressed.",
    )
  }

  const details = []
  const failures = []
  const toCheck = badgedDevices.slice(0, maxDetailChecks)

  for (const device of toCheck) {
    await page.goto(`${baseUrl}${device.href}`, {waitUntil: "domcontentloaded", timeout: 30_000})

    let pillVisible = false
    try {
      await page.waitForSelector(headerPillSelector, {timeout: 15_000})
      pillVisible = true
    } catch (_error) {
      pillVisible = false
    }

    details.push({...device, pillVisible})

    if (!pillVisible) {
      failures.push(device)
    }
  }

  const summary = {
    scannedRows,
    badgedCount: badgedDevices.length,
    checkedCount: toCheck.length,
    skippedCount: badgedDevices.length - toCheck.length,
    passedCount: toCheck.length - failures.length,
    failedCount: failures.length,
    details,
  }

  if (failures.length > 0) {
    const names = failures.map((device) => `${device.label} (${device.href})`).join(", ")
    throw new Error(
      `header Agent pill missing on ${failures.length}/${toCheck.length} badged devices: ${names} — ` +
        `summary ${JSON.stringify(summary)}`,
    )
  }

  return summary
}
