async (page) => {
  // Add-on fleet layout check (OpenSpec refactor-addon-lifecycle-operability, tasks 5.4/5.5).
  //
  // Loads /settings/agents/addons/fleet at a 1440px viewport and asserts:
  //   1. no horizontal scroll on the document or the fleet table container,
  //   2. no clipped/truncated attention badges (content fits its box),
  //   3. no "— (catalog only)" rows inside the fleet matrix,
  //   4. no fabricated "drift:" labels (drift renders as "running X → assigned Y").
  //
  // Env knobs:
  //   PLAYWRIGHT_BASE_URL            (default http://localhost:4000)
  //   PLAYWRIGHT_AUTH_EMAIL / PLAYWRIGHT_AUTH_PASSWORD
  const env = globalThis.process?.env || {}
  const baseUrl = env.PLAYWRIGHT_BASE_URL || "http://localhost:4000"
  const email = env.PLAYWRIGHT_AUTH_EMAIL
  const password = env.PLAYWRIGHT_AUTH_PASSWORD
  const fleetPath = "/settings/agents/addons/fleet"

  await page.setViewportSize({width: 1440, height: 900})

  await page.goto(`${baseUrl}${fleetPath}`, {waitUntil: "domcontentloaded", timeout: 30_000})

  if (page.url().includes("/users/log-in")) {
    if (!email || !password) {
      throw new Error("Set PLAYWRIGHT_AUTH_EMAIL and PLAYWRIGHT_AUTH_PASSWORD before running this check.")
    }

    await page.getByRole("textbox", {name: "Email"}).fill(email)
    await page.getByRole("textbox", {name: "Password"}).fill(password)
    await page.getByRole("button", {name: "Sign in"}).click()
    await page.waitForURL(`**${fleetPath}**`, {timeout: 30_000})
  }

  await page.waitForSelector("#addon-fleet-table, [data-role='fleet-row']", {timeout: 30_000}).catch(() => {})
  await page.waitForTimeout(1_000)

  const result = await page.evaluate(() => {
    const problems = []

    // 1. No horizontal overflow at 1440px: neither the document nor the fleet
    //    table wrapper may scroll horizontally.
    const doc = document.documentElement
    if (doc.scrollWidth > window.innerWidth + 1) {
      problems.push(`document scrollWidth ${doc.scrollWidth} > viewport ${window.innerWidth}`)
    }

    const tableWrap = document.getElementById("addon-fleet-table")
    if (tableWrap && tableWrap.scrollWidth > tableWrap.clientWidth + 1) {
      problems.push(
        `fleet table overflows its container: scrollWidth ${tableWrap.scrollWidth} > clientWidth ${tableWrap.clientWidth}`
      )
    }

    // 2. Badges never clip their text.
    const badges = Array.from(document.querySelectorAll("[data-role='fleet-row'] .badge"))
    for (const badge of badges) {
      if (badge.scrollWidth > badge.clientWidth + 1 || badge.scrollHeight > badge.clientHeight + 1) {
        problems.push(`clipped badge: "${badge.textContent.trim()}"`)
      }
    }

    // 3. Catalog-only entries never render as fleet rows.
    const fleetText = Array.from(document.querySelectorAll("[data-role='fleet-row']"))
      .map((row) => row.textContent)
      .join("\n")
    if (fleetText.includes("(catalog only)")) {
      problems.push("fleet matrix contains a '(catalog only)' row")
    }

    // 4. Drift is always a two-sided comparison, never "drift: <version>".
    if (/drift:\s*\d/.test(document.body.textContent)) {
      problems.push("found a bare 'drift: <version>' label")
    }

    return {
      problems,
      fleetRows: document.querySelectorAll("[data-role='fleet-row']").length,
      catalogRows: document.querySelectorAll("[data-role='catalog-only-row']").length,
      badges: badges.length,
    }
  })

  console.log(
    `addon-fleet layout check: ${result.fleetRows} fleet row(s), ${result.catalogRows} catalog-only row(s), ${result.badges} badge(s) inspected`
  )

  if (result.problems.length > 0) {
    throw new Error(`addon-fleet layout check failed:\n- ${result.problems.join("\n- ")}`)
  }

  console.log("addon-fleet layout check passed")
}
