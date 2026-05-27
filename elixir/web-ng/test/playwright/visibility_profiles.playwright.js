async (page) => {
  const env = globalThis.process?.env || {}
  const baseUrl = env.PLAYWRIGHT_BASE_URL || "http://localhost:4000"
  const email = env.PLAYWRIGHT_AUTH_EMAIL
  const password = env.PLAYWRIGHT_AUTH_PASSWORD
  const profileName = env.PLAYWRIGHT_VISIBILITY_PROFILE_NAME || `PW Visibility ${Date.now()}`
  const profileDescription = "Playwright visibility profile smoke test"
  const editedDescription = "Playwright visibility profile smoke test edited"
  const devicePath =
    env.PLAYWRIGHT_VISIBILITY_DEVICE_PATH ||
    (env.PLAYWRIGHT_VISIBILITY_DEVICE_UID ? `/devices/${env.PLAYWRIGHT_VISIBILITY_DEVICE_UID}` : null)

  async function ensureLoggedIn(targetPath) {
    await page.goto(`${baseUrl}${targetPath}`, {waitUntil: "domcontentloaded", timeout: 30_000})

    if (page.url().includes("/users/log-in")) {
      if (!email || !password) {
        throw new Error("Set PLAYWRIGHT_AUTH_EMAIL and PLAYWRIGHT_AUTH_PASSWORD before running visibility profile checks.")
      }

      await page.getByRole("textbox", {name: "Email"}).fill(email)
      await page.getByRole("textbox", {name: "Password"}).fill(password)
      await page.getByRole("button", {name: "Sign in"}).click()
      await page.waitForURL(`**${targetPath}`, {timeout: 30_000})
    }
  }

  async function setCheckbox(selector, checked) {
    const checkbox = page.locator(selector)
    await checkbox.waitFor({timeout: 10_000})

    if ((await checkbox.isChecked()) !== checked) {
      await checkbox.setChecked(checked)
    }
  }

  async function fillProfileForm({name, description, priority, targetQuery, sampleMs, retentionDays, fingerprint}) {
    await page.locator('input[name="form[name]"]').fill(name)
    await page.locator('input[name="form[description]"]').fill(description)
    await page.locator('input[name="form[priority]"]').fill(String(priority))
    await page.locator('input[name="form[sample_interval_ms]"]').fill(String(sampleMs))
    await page.locator('input[name="form[retention_days]"]').fill(String(retentionDays))
    await page.locator('textarea[name="form[target_query]"]').fill(targetQuery)
    await setCheckbox('input[type="checkbox"][name="form[enabled]"]', true)
    await setCheckbox('input[type="checkbox"][name="form[fingerprint][tcp]"]', fingerprint.tcp)
    await setCheckbox('input[type="checkbox"][name="form[fingerprint][tls]"]', fingerprint.tls)
    await setCheckbox('input[type="checkbox"][name="form[fingerprint][http]"]', fingerprint.http)
  }

  function profileRow(name) {
    return page.locator("tbody tr").filter({hasText: name}).first()
  }

  async function expectVisible(locator, message) {
    try {
      await locator.waitFor({state: "visible", timeout: 15_000})
    } catch (error) {
      throw new Error(message)
    }
  }

  async function createProfile() {
    await ensureLoggedIn("/settings/networks/visibility-profiles")
    await page.waitForURL("**/settings/networks/visibility-profiles", {timeout: 15_000})
    await page.getByRole("link", {name: /New Profile/i}).click()
    await page.waitForURL("**/settings/networks/visibility-profiles/new", {timeout: 15_000})

    await fillProfileForm({
      name: profileName,
      description: profileDescription,
      priority: 25,
      targetQuery: "in:devices type:0",
      sampleMs: 30_000,
      retentionDays: 14,
      fingerprint: {tcp: true, tls: true, http: false},
    })

    await page.getByRole("button", {name: /Save Profile/i}).click()
    await page.waitForURL("**/settings/networks/visibility-profiles", {timeout: 15_000})
    await expectVisible(profileRow(profileName), `Created visibility profile ${profileName} was not visible in the list.`)

    const row = profileRow(profileName)
    for (const expected of ["Enabled", "TCP", "TLS", "14d"]) {
      if (!(await row.getByText(expected, {exact: true}).count())) {
        throw new Error(`Created visibility profile row did not include ${expected}.`)
      }
    }

    if (await row.getByText("HTTP", {exact: true}).count()) {
      throw new Error("Created visibility profile row unexpectedly enabled HTTP fingerprinting.")
    }
  }

  async function editAndPreviewProfile() {
    await profileRow(profileName).getByTitle("Edit profile").click()
    await page.waitForURL("**/settings/networks/visibility-profiles/*/edit", {timeout: 15_000})

    await fillProfileForm({
      name: profileName,
      description: editedDescription,
      priority: 10,
      targetQuery: "in:devices type:0",
      sampleMs: 45_000,
      retentionDays: 21,
      fingerprint: {tcp: true, tls: true, http: true},
    })

    await page.getByRole("button", {name: /Save Profile/i}).click()
    await page.waitForURL("**/settings/networks/visibility-profiles", {timeout: 15_000})

    const row = profileRow(profileName)
    await expectVisible(row, `Edited visibility profile ${profileName} was not visible in the list.`)

    for (const expected of [editedDescription, "TCP", "TLS", "HTTP", "21d"]) {
      if (!(await row.getByText(expected, {exact: true}).count())) {
        throw new Error(`Edited visibility profile row did not include ${expected}.`)
      }
    }

    await row.getByTitle("Preview config").click()
    await expectVisible(page.getByText("Compiled Visibility Config", {exact: true}), "Visibility profile preview modal did not open.")
    await expectVisible(page.getByText(profileName), "Visibility profile preview did not include the profile name.")
    await page.getByRole("button", {name: "Close"}).click()
    await page.getByText("Compiled Visibility Config", {exact: true}).waitFor({state: "detached", timeout: 10_000})
  }

  async function deleteProfile() {
    const row = profileRow(profileName)

    page.once("dialog", async (dialog) => {
      await dialog.accept()
    })

    await row.getByTitle("Delete profile").click()
    await page.getByText(profileName).waitFor({state: "detached", timeout: 15_000})
  }

  async function verifyDeviceFingerprintPanel() {
    if (!devicePath) {
      throw new Error(
        "Set PLAYWRIGHT_VISIBILITY_DEVICE_PATH or PLAYWRIGHT_VISIBILITY_DEVICE_UID to a device detail page with passive fingerprint metadata."
      )
    }

    await ensureLoggedIn(devicePath)
    await page.waitForURL(`**${devicePath}`, {timeout: 15_000})

    const panel = page
      .locator("div")
      .filter({has: page.getByText("Network Visibility", {exact: true})})
      .filter({has: page.getByText("Passive fingerprint", {exact: true})})
      .first()

    await expectVisible(panel, "Device detail passive fingerprint panel was not visible.")

    const protocolCount = await panel.getByText(/^(TCP|TLS|HTTP)$/).count()
    if (protocolCount === 0) {
      throw new Error("Device detail passive fingerprint panel did not render any protocol cards.")
    }

    const labels = ["OS family", "OS name", "Signature", "JA4", "JA4S", "Server", "User agent", "Accept language"]
    let matchedLabel = null

    for (const label of labels) {
      if (await panel.getByText(label, {exact: true}).count()) {
        matchedLabel = label
        break
      }
    }

    if (!matchedLabel) {
      throw new Error("Device detail passive fingerprint panel rendered no known fingerprint metadata labels.")
    }

    return {path: devicePath, protocolCount, matchedLabel}
  }

  const results = []

  try {
    await createProfile()
    results.push({name: "visibility profile create", profileName})

    await editAndPreviewProfile()
    results.push({name: "visibility profile edit and preview", profileName})

    const devicePanel = await verifyDeviceFingerprintPanel()
    results.push({name: "device detail passive fingerprint panel", ...devicePanel})
  } finally {
    await ensureLoggedIn("/settings/networks/visibility-profiles")

    if (await profileRow(profileName).count()) {
      await deleteProfile()
      results.push({name: "visibility profile delete", profileName})
    }
  }

  return results
}
