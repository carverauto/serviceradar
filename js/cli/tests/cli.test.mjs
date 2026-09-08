import assert from "node:assert/strict"
import {execFile} from "node:child_process"
import {mkdtemp, readFile, stat, writeFile} from "node:fs/promises"
import {tmpdir} from "node:os"
import {join} from "node:path"
import {promisify} from "node:util"
import test from "node:test"

const execFileAsync = promisify(execFile)
const cliPath = new URL("../bin/serviceradar-cli.js", import.meta.url)

test("manifest command writes renderer digest from dashboard config", async () => {
  const projectDir = await mkdtemp(join(tmpdir(), "sr-dashboard-cli-"))
  await writeFile(join(projectDir, "dashboard.config.json"), JSON.stringify({
    manifest: {
      id: "com.example.dashboard",
      name: "Example Dashboard",
      version: "1.2.3",
      vendor: "Example",
      renderer: {
        artifact: "renderer.js",
      },
      data_frames: [],
      capabilities: ["srql.execute"],
    },
  }))
  await execFileAsync("mkdir", ["-p", join(projectDir, "dist")])
  await writeFile(join(projectDir, "dist", "renderer.js"), "export function mountDashboard() {}\n")

  const {stdout} = await execFileAsync(process.execPath, [cliPath.pathname, "manifest"], {cwd: projectDir})
  const manifest = JSON.parse(await readFile(join(projectDir, "dist", "manifest.json"), "utf8"))

  assert.match(stdout, /Wrote dist\/manifest\.json/)
  assert.equal(manifest.id, "com.example.dashboard")
  assert.equal(manifest.renderer.kind, "browser_module")
  assert.equal(manifest.renderer.interface_version, "dashboard-browser-module-v1")
  assert.equal(manifest.renderer.entrypoint, "mountDashboard")
  assert.match(manifest.renderer.sha256, /^[a-f0-9]{64}$/)
})

test("help command documents the dashboard workflow + auth group", async () => {
  const {stdout} = await execFileAsync(process.execPath, [cliPath.pathname, "help"])

  assert.match(stdout, /serviceradar-cli/)
  assert.match(stdout, /serviceradar-cli dashboard build/)
  assert.match(stdout, /serviceradar-cli dashboard manifest/)
  assert.match(stdout, /serviceradar-cli dashboard validate/)
  assert.match(stdout, /serviceradar-cli dashboard dev/)
  assert.match(stdout, /serviceradar-cli dashboard import/)
  assert.match(stdout, /serviceradar-cli auth login/)
  assert.match(stdout, /serviceradar-cli auth status/)
  assert.match(stdout, /serviceradar-cli auth logout/)
  assert.match(stdout, /notifications/)
})

test("validate accepts a clean dashboard config", async () => {
  const projectDir = await mkdtemp(join(tmpdir(), "sr-dashboard-validate-"))
  await execFileAsync("mkdir", ["-p", join(projectDir, "src")])
  await writeFile(join(projectDir, "src/main.jsx"), "export function mountDashboard() {}\n")
  await writeFile(join(projectDir, "fixtures.json"), JSON.stringify([
    {id: "sites", results: [{site_code: "ZZC"}]},
  ]))
  await writeFile(join(projectDir, "settings.json"), JSON.stringify({mapbox: {access_token: "pk.example"}}))
  await writeFile(join(projectDir, "dashboard.config.json"), JSON.stringify({
    manifest: {
      id: "com.example.dashboard",
      name: "Example",
      version: "1.0.0",
      data_frames: [{id: "sites"}],
    },
    samples: {frames: "fixtures.json", settings: "settings.json"},
  }))

  const {stdout} = await execFileAsync(process.execPath, [cliPath.pathname, "validate"], {cwd: projectDir})

  assert.match(stdout, /Dashboard config validates\./)
  assert.match(stdout, /manifest id com\.example\.dashboard@1\.0\.0/)
})

test("validate flags a missing manifest field", async () => {
  const projectDir = await mkdtemp(join(tmpdir(), "sr-dashboard-validate-fail-"))
  await execFileAsync("mkdir", ["-p", join(projectDir, "src")])
  await writeFile(join(projectDir, "src/main.jsx"), "export function mountDashboard() {}\n")
  await writeFile(join(projectDir, "dashboard.config.json"), JSON.stringify({
    manifest: {
      id: "com.example.dashboard",
      // name + version intentionally missing
    },
  }))

  await assert.rejects(
    () => execFileAsync(process.execPath, [cliPath.pathname, "validate"], {cwd: projectDir}),
    (error) => {
      assert.match(error.stderr, /Dashboard config validation failed/)
      assert.match(error.stderr, /\/manifest: missing required property "name"/)
      assert.match(error.stderr, /\/manifest: missing required property "version"/)
      assert.notEqual(error.code, 0)
      return true
    },
  )
})

test("validate flags an unknown top-level property as a typo", async () => {
  const projectDir = await mkdtemp(join(tmpdir(), "sr-dashboard-validate-typo-"))
  await execFileAsync("mkdir", ["-p", join(projectDir, "src")])
  await writeFile(join(projectDir, "src/main.jsx"), "export function mountDashboard() {}\n")
  await writeFile(join(projectDir, "dashboard.config.json"), JSON.stringify({
    manifest: {id: "com.example.dashboard", name: "Demo", version: "1.0.0"},
    renderer: {entry: "src/main.jsx"},
    fixtuers: {hello: "fixtures/sample-frames.json"}, // typo of "fixtures"
  }))

  await assert.rejects(
    () => execFileAsync(process.execPath, [cliPath.pathname, "validate"], {cwd: projectDir}),
    (error) => {
      assert.match(error.stderr, /unknown property "fixtuers"/)
      assert.match(error.stderr, /check for typos/)
      return true
    },
  )
})

test("validate rejects an invalid version pattern with a semver hint", async () => {
  const projectDir = await mkdtemp(join(tmpdir(), "sr-dashboard-validate-semver-"))
  await execFileAsync("mkdir", ["-p", join(projectDir, "src")])
  await writeFile(join(projectDir, "src/main.jsx"), "export function mountDashboard() {}\n")
  await writeFile(join(projectDir, "dashboard.config.json"), JSON.stringify({
    manifest: {id: "com.example.dashboard", name: "Demo", version: "v1.0"},
    renderer: {entry: "src/main.jsx"},
  }))

  await assert.rejects(
    () => execFileAsync(process.execPath, [cliPath.pathname, "validate"], {cwd: projectDir}),
    (error) => {
      assert.match(error.stderr, /\/manifest\/version.*does not match required pattern/)
      assert.match(error.stderr, /use semver/)
      return true
    },
  )
})

test("validate flags a sample-frames declared-but-missing entry", async () => {
  const projectDir = await mkdtemp(join(tmpdir(), "sr-dashboard-validate-frames-"))
  await execFileAsync("mkdir", ["-p", join(projectDir, "src")])
  await writeFile(join(projectDir, "src/main.jsx"), "export function mountDashboard() {}\n")
  await writeFile(join(projectDir, "fixtures.json"), JSON.stringify([{id: "sites", results: []}]))
  await writeFile(join(projectDir, "dashboard.config.json"), JSON.stringify({
    manifest: {
      id: "com.example.dashboard",
      name: "Example",
      version: "1.0.0",
      data_frames: [{id: "sites"}, {id: "controllers"}],
    },
    samples: {frames: "fixtures.json"},
  }))

  await assert.rejects(
    () => execFileAsync(process.execPath, [cliPath.pathname, "validate"], {cwd: projectDir}),
    (error) => {
      assert.match(error.stderr, /declares "controllers" but samples\.frames does not provide a sample/)
      return true
    },
  )
})

test("init scaffolds the react-blank template and swizzles placeholders", async () => {
  const parentDir = await mkdtemp(join(tmpdir(), "sr-dashboard-init-"))
  const projectName = "smoke-blank"

  const {stdout} = await execFileAsync(
    process.execPath,
    [cliPath.pathname, "init", projectName, "--template", "react-blank", "--no-install"],
    {cwd: parentDir},
  )

  assert.match(stdout, /Scaffolding smoke-blank from template "react-blank"/)
  assert.match(stdout, /npm run dev/)

  const configContent = await readFile(join(parentDir, projectName, "dashboard.config.mjs"), "utf8")
  assert.match(configContent, /id: "com\.example\.smoke-blank"/)
  assert.match(configContent, /name: "Smoke Blank"/)
  assert.doesNotMatch(configContent, /__PACKAGE_ID__/)
  assert.doesNotMatch(configContent, /__DASHBOARD_TITLE__/)

  const packageJson = JSON.parse(await readFile(join(parentDir, projectName, "package.json"), "utf8"))
  assert.equal(packageJson.name, "smoke-blank")
  assert.equal(packageJson.scripts.dev, "serviceradar-cli dashboard dev")
})

test("init refuses to overwrite a non-empty target without --force", async () => {
  const parentDir = await mkdtemp(join(tmpdir(), "sr-dashboard-init-existing-"))
  await execFileAsync("mkdir", ["-p", join(parentDir, "occupied")])
  await writeFile(join(parentDir, "occupied", "README.md"), "existing content\n")

  await assert.rejects(
    () => execFileAsync(
      process.execPath,
      [cliPath.pathname, "init", "occupied", "--template", "react-blank", "--no-install"],
      {cwd: parentDir},
    ),
    (error) => {
      assert.match(error.stderr, /target directory already exists and is not empty/)
      assert.match(error.stderr, /--force/)
      return true
    },
  )
})

test("init react-map template lays out fixtures + map entry", async () => {
  const parentDir = await mkdtemp(join(tmpdir(), "sr-dashboard-init-map-"))
  await execFileAsync(
    process.execPath,
    [cliPath.pathname, "init", "smoke-map", "--template", "react-map", "--package-id", "com.acme.network", "--title", "Acme Network", "--no-install"],
    {cwd: parentDir},
  )

  const configContent = await readFile(join(parentDir, "smoke-map", "dashboard.config.mjs"), "utf8")
  assert.match(configContent, /id: "com\.acme\.network"/)
  assert.match(configContent, /name: "Acme Network"/)

  const fixturePath = join(parentDir, "smoke-map", "fixtures", "sample-frames.json")
  const fixturePayload = JSON.parse(await readFile(fixturePath, "utf8"))
  assert.equal(fixturePayload[0].id, "sites")
  assert.ok(fixturePayload[0].results.length >= 4)

  const mainEntry = await readFile(join(parentDir, "smoke-map", "src", "main.jsx"), "utf8")
  assert.match(mainEntry, /useDeckMap/)
  assert.match(mainEntry, /useFrameRows/)
})

test("auth login --web completes a PKCE flow against a stub authorize+token server", async () => {
  const credsHome = await mkdtemp(join(tmpdir(), "sr-cli-auth-pkce-"))
  const {createServer} = await import("node:http")
  const {spawn} = await import("node:child_process")

  const captured = {
    authorizeQuery: null,
    tokenBody: null,
    probeMethod: null,
  }

  const server = createServer((req, res) => {
    const url = new URL(req.url, `http://127.0.0.1`)
    if (url.pathname === "/api/v1/cli/auth/authorize") {
      // First hit is the CLI's probe (redirect: manual) — record the method
      // and respond with an HTTP redirect that includes the code + state.
      // The CLI ignores the redirect target on probes; the simulated
      // browser GET (issued from the test below with redirect:follow)
      // follows the redirect and hits the CLI's local callback server.
      captured.authorizeQuery = Object.fromEntries(url.searchParams)
      captured.probeMethod = req.method
      const redirect = url.searchParams.get("redirect_uri")
      const state = url.searchParams.get("state")
      if (!redirect) {
        res.writeHead(400)
        res.end("missing redirect_uri")
        return
      }
      const dest = new URL(redirect)
      dest.searchParams.set("code", "stub-auth-code")
      dest.searchParams.set("state", state || "")
      res.writeHead(302, {location: dest.toString()})
      res.end()
      return
    }
    if (url.pathname === "/api/v1/cli/auth/token") {
      let body = ""
      req.on("data", (chunk) => {
        body += chunk
      })
      req.on("end", () => {
        captured.tokenBody = body ? JSON.parse(body) : null
        res.writeHead(200, {"content-type": "application/json"})
        res.end(JSON.stringify({
          access_token: "pkce-issued-token-xyz",
          token_type: "Bearer",
          expires_in: 86400,
          user: "alice@example.com",
        }))
      })
      return
    }
    res.writeHead(404)
    res.end()
  })
  await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen))
  const port = server.address().port
  const instance = `http://127.0.0.1:${port}`

  try {
    const child = spawn(
      process.execPath,
      [cliPath.pathname, "auth", "login", "--instance", instance, "--web", "--no-browser"],
      {env: {...process.env, HOME: credsHome, XDG_CONFIG_HOME: credsHome, SERVICERADAR_TOKEN: ""}, stdio: ["ignore", "pipe", "pipe"]},
    )

    let stdout = ""
    let stderr = ""
    let triggered = false

    child.stdout.setEncoding("utf8")
    child.stdout.on("data", (chunk) => {
      stdout += chunk
      if (!triggered) {
        const match = stdout.match(/(http:\/\/127\.0\.0\.1:\d+\/api\/v1\/cli\/auth\/authorize\?[^\s]+)/)
        if (match) {
          triggered = true
          // Simulate the browser following the authorize URL → 302 → callback.
          fetch(match[1], {redirect: "follow"}).catch(() => {/* swallow */})
        }
      }
    })
    child.stderr.setEncoding("utf8")
    child.stderr.on("data", (chunk) => {
      stderr += chunk
    })

    const exitCode = await new Promise((res, rej) => {
      const timer = setTimeout(() => {
        child.kill("SIGTERM")
        rej(new Error(`CLI did not exit within 15s. stdout=${stdout} stderr=${stderr}`))
      }, 15_000)
      child.on("close", (code) => {
        clearTimeout(timer)
        res(code)
      })
    })

    assert.equal(exitCode, 0, `CLI exited with code ${exitCode}\nstdout=${stdout}\nstderr=${stderr}`)
    assert.match(stdout, /Authenticated/)
    assert.equal(captured.authorizeQuery?.response_type, "code")
    assert.equal(captured.authorizeQuery?.client_id, "serviceradar-cli")
    assert.equal(captured.authorizeQuery?.code_challenge_method, "S256")
    assert.match(captured.authorizeQuery?.code_challenge || "", /^[A-Za-z0-9_-]{43}$/)
    assert.match(captured.authorizeQuery?.state || "", /^[A-Za-z0-9_-]+$/)
    assert.match(captured.authorizeQuery?.redirect_uri || "", /^http:\/\/127\.0\.0\.1:\d+\/cli\/auth\/callback$/)

    assert.equal(captured.tokenBody?.grant_type, "authorization_code")
    assert.equal(captured.tokenBody?.code, "stub-auth-code")
    assert.match(captured.tokenBody?.code_verifier || "", /^[A-Za-z0-9_-]{43}$/)

    const stored = JSON.parse(await readFile(join(credsHome, "serviceradar", "credentials.json"), "utf8"))
    assert.equal(stored.instances?.[instance]?.token, "pkce-issued-token-xyz")
    assert.equal(stored.instances?.[instance]?.user, "alice@example.com")
  } finally {
    await new Promise((resolveClose) => server.close(resolveClose))
  }
})

test("auth login --web falls back to manual token when authorize endpoint is missing", async () => {
  const credsHome = await mkdtemp(join(tmpdir(), "sr-cli-auth-pkce-fallback-"))
  const {createServer} = await import("node:http")
  const server = createServer((req, res) => {
    res.writeHead(404, {"content-type": "application/json"})
    res.end(JSON.stringify({error: "endpoint not implemented"}))
  })
  await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen))
  const port = server.address().port
  const instance = `http://127.0.0.1:${port}`

  try {
    const {stderr} = await execFileAsync(
      process.execPath,
      [cliPath.pathname, "auth", "login", "--instance", instance, "--web", "--no-browser", "--token", "manual-pkce-fallback-token"],
      {env: {...process.env, HOME: credsHome, XDG_CONFIG_HOME: credsHome, SERVICERADAR_TOKEN: ""}},
    )
    assert.match(stderr, /PKCE web login is not available/)
    assert.match(stderr, /Falling back to manual token entry/)

    const stored = JSON.parse(await readFile(join(credsHome, "serviceradar", "credentials.json"), "utf8"))
    assert.equal(stored.instances?.[instance]?.token, "manual-pkce-fallback-token")
  } finally {
    await new Promise((resolveClose) => server.close(resolveClose))
  }
})

test("init rejects an unknown template", async () => {
  const parentDir = await mkdtemp(join(tmpdir(), "sr-dashboard-init-bad-"))
  await assert.rejects(
    () => execFileAsync(
      process.execPath,
      [cliPath.pathname, "init", "smoke-bad", "--template", "react-quantum", "--no-install"],
      {cwd: parentDir},
    ),
    (error) => {
      assert.match(error.stderr, /unknown template: react-quantum/)
      assert.match(error.stderr, /react-blank/)
      return true
    },
  )
})

for (const template of ["react-blank", "react-map", "react-table"]) {
  test(`init scaffold for ${template} produces a structurally complete project`, async () => {
    const parentDir = await mkdtemp(join(tmpdir(), `sr-dashboard-tmpl-${template}-`))
    const projectName = `${template}-smoke`
    const packageId = `com.example.${template.replace(/-/g, "")}`
    await execFileAsync(
      process.execPath,
      [cliPath.pathname, "init", projectName, "--template", template, "--no-install", "--package-id", packageId, "--title", `${template} smoke`],
      {cwd: parentDir},
    )

    const projectDir = join(parentDir, projectName)

    const pkg = JSON.parse(await readFile(join(projectDir, "package.json"), "utf8"))
    assert.equal(pkg.name, projectName)
    assert.match(pkg.scripts.dev, /serviceradar-cli dashboard dev/)
    assert.match(pkg.scripts.build, /serviceradar-cli dashboard build/)
    assert.match(pkg.scripts.validate, /serviceradar-cli dashboard validate/)
    assert.equal(pkg.dependencies["@carverauto/serviceradar-dashboard-sdk"]?.startsWith("^") ?? false, true)

    const config = await readFile(join(projectDir, "dashboard.config.mjs"), "utf8")
    assert.match(config, new RegExp(`id: "${packageId.replace(/\./g, "\\.")}"`))
    assert.match(config, /defineDashboardConfig/)
    assert.match(config, /@carverauto\/serviceradar-dashboard-sdk\/config/)

    const entryMatch = config.match(/entry:\s*"([^"]+)"/)
    assert.ok(entryMatch, "renderer.entry not declared in dashboard.config.mjs")
    const entryStat = await stat(join(projectDir, entryMatch[1]))
    assert.equal(entryStat.isFile(), true, `renderer entry ${entryMatch[1]} missing`)

    const fixturesMatch = [...config.matchAll(/path:\s*"([^"]+)"/g)].map((m) => m[1])
    for (const fixturePath of fixturesMatch) {
      const fStat = await stat(join(projectDir, fixturePath))
      assert.equal(fStat.isFile(), true, `fixture ${fixturePath} missing`)
    }
  })
}

test("validate flags a missing renderer entry with a suggested fix", async () => {
  const projectDir = await mkdtemp(join(tmpdir(), "sr-dashboard-validate-entry-"))
  await writeFile(join(projectDir, "dashboard.config.json"), JSON.stringify({
    manifest: {id: "com.example.dashboard", name: "Example", version: "1.0.0"},
    renderer: {entry: "src/missing.jsx"},
  }))

  await assert.rejects(
    () => execFileAsync(process.execPath, [cliPath.pathname, "validate"], {cwd: projectDir}),
    (error) => {
      assert.match(error.stderr, /renderer entry does not exist: src\/missing\.jsx/)
      assert.match(error.stderr, /set `renderer\.entry`/)
      return true
    },
  )
})

test("publish posts manifest + renderer to the instance and uses the resolved token", async () => {
  const projectDir = await mkdtemp(join(tmpdir(), "sr-dashboard-publish-"))
  await execFileAsync("mkdir", ["-p", join(projectDir, "src"), join(projectDir, "dist")])
  await writeFile(join(projectDir, "src/main.jsx"), "export function mountDashboard() {}\n")
  await writeFile(join(projectDir, "dashboard.config.json"), JSON.stringify({
    manifest: {
      id: "com.example.dashboard",
      name: "Example",
      version: "1.0.0",
      vendor: "Example",
      data_frames: [],
      renderer: {kind: "browser_module", interface_version: "dashboard-browser-module-v1", entrypoint: "mountDashboard", trust: "trusted"},
    },
  }))

  const rendererBody = "export function mountDashboard() {}\n"
  await writeFile(join(projectDir, "dist/renderer.js"), rendererBody)

  // Stamp the manifest from the renderer the same way `dashboard build` does.
  await execFileAsync(process.execPath, [cliPath.pathname, "manifest"], {cwd: projectDir})

  // Stub server captures the import request.
  const {createServer} = await import("node:http")
  const requests = []
  const server = createServer((req, res) => {
    requests.push({method: req.method, url: req.url, headers: req.headers})
    let body = []
    req.on("data", (chunk) => body.push(chunk))
    req.on("end", () => {
      const buffer = Buffer.concat(body)
      requests[requests.length - 1].body = buffer
      res.writeHead(200, {"content-type": "application/json"})
      res.end(JSON.stringify({id: "com.example.dashboard"}))
    })
  })
  await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen))
  const port = server.address().port
  const instance = `http://127.0.0.1:${port}`

  try {
    const {stdout} = await execFileAsync(
      process.execPath,
      [cliPath.pathname, "dashboard", "publish", "--instance", instance, "--route", "demo", "--token", "test-token", "--yes"],
      {cwd: projectDir, env: {...process.env, SERVICERADAR_TOKEN: ""}},
    )

    assert.match(stdout, /Publish summary:/)
    assert.match(stdout, /Published com\.example\.dashboard@1\.0\.0/)

    assert.equal(requests.length, 1)
    assert.equal(requests[0].method, "POST")
    assert.equal(requests[0].url, "/api/v1/dashboard-packages")
    assert.equal(requests[0].headers.authorization, "Bearer test-token")

    const bodyText = requests[0].body.toString("utf8")
    assert.match(bodyText, /com\.example\.dashboard/, "manifest payload should be in the multipart body")
    assert.match(bodyText, /export function mountDashboard\(\)/, "renderer artifact should be in the multipart body")
    assert.match(bodyText, /name="route"\s*\r\n\s*\r\ndemo/, "route field present")
  } finally {
    await new Promise((resolveClose) => server.close(resolveClose))
  }
})

test("publish refuses on a manifest digest mismatch with a clear message", async () => {
  const projectDir = await mkdtemp(join(tmpdir(), "sr-dashboard-publish-mismatch-"))
  await execFileAsync("mkdir", ["-p", join(projectDir, "src"), join(projectDir, "dist")])
  await writeFile(join(projectDir, "src/main.jsx"), "export function mountDashboard() {}\n")
  await writeFile(join(projectDir, "dashboard.config.json"), JSON.stringify({
    manifest: {
      id: "com.example.dashboard",
      name: "Example",
      version: "1.0.0",
      data_frames: [],
      renderer: {kind: "browser_module", interface_version: "dashboard-browser-module-v1", entrypoint: "mountDashboard", trust: "trusted"},
    },
  }))
  await writeFile(join(projectDir, "dist/renderer.js"), "export function mountDashboard() {}\n")
  await execFileAsync(process.execPath, [cliPath.pathname, "manifest"], {cwd: projectDir})

  // Tamper with the renderer so its digest no longer matches the manifest.
  await writeFile(join(projectDir, "dist/renderer.js"), "export function mountDashboard() { /* tampered */ }\n")

  await assert.rejects(
    () => execFileAsync(
      process.execPath,
      [cliPath.pathname, "dashboard", "publish", "--instance", "http://127.0.0.1:0", "--route", "demo", "--token", "t", "--yes"],
      {cwd: projectDir, env: {...process.env, SERVICERADAR_TOKEN: ""}},
    ),
    (error) => {
      assert.match(error.stderr, /manifest renderer digest .* does not match/)
      assert.match(error.stderr, /serviceradar-cli dashboard build/)
      return true
    },
  )
})

test("publish refuses when no credential is resolvable", async () => {
  const projectDir = await mkdtemp(join(tmpdir(), "sr-dashboard-publish-noauth-"))
  await execFileAsync("mkdir", ["-p", join(projectDir, "src"), join(projectDir, "dist")])
  await writeFile(join(projectDir, "src/main.jsx"), "export function mountDashboard() {}\n")
  await writeFile(join(projectDir, "dashboard.config.json"), JSON.stringify({
    manifest: {
      id: "com.example.dashboard",
      name: "Example",
      version: "1.0.0",
      data_frames: [],
      renderer: {kind: "browser_module", interface_version: "dashboard-browser-module-v1", entrypoint: "mountDashboard", trust: "trusted"},
    },
  }))
  await writeFile(join(projectDir, "dist/renderer.js"), "export function mountDashboard() {}\n")
  await execFileAsync(process.execPath, [cliPath.pathname, "manifest"], {cwd: projectDir})

  // Point credentials at a fresh empty dir so no stored token is found.
  const credsHome = await mkdtemp(join(tmpdir(), "sr-dashboard-publish-credshome-"))

  await assert.rejects(
    () => execFileAsync(
      process.execPath,
      [cliPath.pathname, "dashboard", "publish", "--instance", "https://serviceradar.example.com", "--route", "demo", "--yes"],
      {
        cwd: projectDir,
        env: {...process.env, HOME: credsHome, SERVICERADAR_TOKEN: "", XDG_CONFIG_HOME: credsHome},
      },
    ),
    (error) => {
      assert.match(error.stderr, /no token resolved/)
      assert.match(error.stderr, /serviceradar-cli auth login/)
      return true
    },
  )
})

test("--version prints the installed CLI version", async () => {
  const {stdout} = await execFileAsync(process.execPath, [cliPath.pathname, "--version"])
  assert.match(stdout, /^@carverauto\/serviceradar-cli \d+\.\d+\.\d+/m)
})

test("doctor prints runtime + project diagnostics", async () => {
  const {stdout} = await execFileAsync(process.execPath, [cliPath.pathname, "doctor"])
  assert.match(stdout, /ServiceRadar CLI doctor/)
  assert.match(stdout, /node:\s+v\d+/)
  assert.match(stdout, /platform:/)
  assert.match(stdout, /@carverauto\/serviceradar-cli:\s+\d+\.\d+\.\d+/)
  assert.match(stdout, /credentials path:/)
})

test("formatFetchFailure explains private-CA TLS errors", async () => {
  const {formatFetchFailure, isTlsTrustError} = await import("../dist/tls_ca.js")
  const error = Object.assign(new Error("fetch failed"), {
    cause: Object.assign(new Error("unable to get local issuer certificate"), {
      code: "UNABLE_TO_GET_ISSUER_CERT_LOCALLY",
    }),
  })
  assert.equal(isTlsTrustError(error), true)
  const formatted = formatFetchFailure(error)
  assert.match(formatted, /UNABLE_TO_GET_ISSUER_CERT_LOCALLY/)
  assert.match(formatted, /does not use the OS certificate store/)
  assert.match(formatted, /ca-bundle\.pem/)
})

test("doctor names a PEM it can see but will not load", async () => {
  const credsHome = await mkdtemp(join(tmpdir(), "sr-cli-doctor-pem-"))
  const bundleDir = join(credsHome, "serviceradar")
  await execFileAsync("mkdir", ["-p", bundleDir])
  // Deliberately NOT ca-bundle.pem. This is the silent miss: the operator
  // believes the CA is installed, autodetect never looks at it, and the only
  // symptom is a bare `fetch failed`.
  const misnamed = join(bundleDir, "corp-ca-bundle.pem")
  await writeFile(misnamed, "-----BEGIN CERTIFICATE-----\nnot-a-real-cert\n-----END CERTIFICATE-----\n")

  const {stdout} = await execFileAsync(
    process.execPath,
    [cliPath.pathname, "doctor"],
    {env: {...process.env, HOME: credsHome, XDG_CONFIG_HOME: credsHome, NODE_EXTRA_CA_CERTS: "", SERVICERADAR_CA_FILE: ""}},
  )
  assert.match(stdout, /unused PEM:.*corp-ca-bundle\.pem/)
  assert.match(stdout, /rename it to .*ca-bundle\.pem/)
})

test("describeError surfaces the cause Node hides behind `fetch failed`", async () => {
  const {describeError} = await import("../dist/tls_ca.js")

  // Node reports every fetch fault as a bare TypeError and puts the reason on
  // .cause, so printing error.message alone is an unexplained crash.
  const refused = Object.assign(new TypeError("fetch failed"), {
    cause: Object.assign(new Error("connect ECONNREFUSED 127.0.0.1:1"), {code: "ECONNREFUSED"}),
  })
  assert.match(describeError(refused), /ECONNREFUSED/)

  // A message that already carries its own detail is not annotated twice.
  const already = new Error("publish request failed: nope (ECONNREFUSED)")
  assert.equal(describeError(already), "publish request failed: nope (ECONNREFUSED)")

  // A plain error is passed through untouched.
  assert.equal(describeError(new Error("--route is required")), "--route is required")

  // A cause with no `code` still has to surface its message — that sentence is
  // the only information the failure carries.
  const codeless = Object.assign(new TypeError("fetch failed"), {cause: new Error("bad port")})
  assert.match(describeError(codeless), /bad port/)
})

test("caFileFromArgv accepts both --ca-file spellings", async () => {
  const {caFileFromArgv} = await import("../dist/tls_ca.js")
  assert.equal(caFileFromArgv(["node", "cli", "--ca-file", "/tmp/a.pem"]), "/tmp/a.pem")
  assert.equal(caFileFromArgv(["node", "cli", "--ca-file=/tmp/b.pem"]), "/tmp/b.pem")
  assert.equal(caFileFromArgv(["node", "cli", "--ca-file", "--yes"]), undefined)
  assert.equal(caFileFromArgv(["node", "cli"]), undefined)
})

test("publish reports why the upload failed instead of a bare `fetch failed`", async () => {
  const projectDir = await mkdtemp(join(tmpdir(), "sr-dashboard-publish-netfail-"))
  await execFileAsync("mkdir", ["-p", join(projectDir, "src"), join(projectDir, "dist")])
  await writeFile(join(projectDir, "src/main.jsx"), "export function mountDashboard() {}\n")
  await writeFile(join(projectDir, "dashboard.config.json"), JSON.stringify({
    manifest: {
      id: "com.example.dashboard",
      name: "Example",
      version: "1.0.0",
      data_frames: [],
      renderer: {kind: "browser_module", interface_version: "dashboard-browser-module-v1", entrypoint: "mountDashboard", trust: "trusted"},
    },
  }))
  await writeFile(join(projectDir, "dist/renderer.js"), "export function mountDashboard() {}\n")
  await execFileAsync(process.execPath, [cliPath.pathname, "manifest"], {cwd: projectDir})

  await assert.rejects(
    () => execFileAsync(
      process.execPath,
      [cliPath.pathname, "dashboard", "publish", "--instance", "http://127.0.0.1:45999", "--route", "demo", "--token", "t", "--yes"],
      {cwd: projectDir, env: {...process.env, SERVICERADAR_TOKEN: ""}},
    ),
    (error) => {
      // The URL that was tried, and the reason it failed.
      assert.match(error.stderr, /publish request to http:\/\/127\.0\.0\.1:45999\/api\/v1\/dashboard-packages failed/)
      assert.match(error.stderr, /ECONNREFUSED/)
      assert.doesNotMatch(error.stderr, /^fetch failed$/m)
      return true
    },
  )
})

test("auth login reports network failures instead of the missing-endpoint fallback", async () => {
  const credsHome = await mkdtemp(join(tmpdir(), "sr-cli-auth-netfail-"))
  await assert.rejects(
    () => execFileAsync(
      process.execPath,
      [cliPath.pathname, "auth", "login", "--instance", "https://127.0.0.1:1", "--no-browser", "--token", "manual-token-abc"],
      {env: {...process.env, HOME: credsHome, XDG_CONFIG_HOME: credsHome, SERVICERADAR_TOKEN: "", NODE_EXTRA_CA_CERTS: ""}},
    ),
    (error) => {
      assert.match(error.stderr, /device-code request failed/)
      assert.doesNotMatch(error.stderr, /Device-code login is not available/)
      return true
    },
  )
})

test("auth login re-execs with a configured CA bundle and still runs --version", async () => {
  const credsHome = await mkdtemp(join(tmpdir(), "sr-cli-auth-ca-"))
  const bundleDir = join(credsHome, "serviceradar")
  await execFileAsync("mkdir", ["-p", bundleDir])
  const bundlePath = join(bundleDir, "ca-bundle.pem")
  await execFileAsync("openssl", [
    "req", "-x509", "-newkey", "rsa:2048", "-nodes",
    "-keyout", join(bundleDir, "key.pem"),
    "-out", bundlePath,
    "-days", "1",
    "-subj", "/CN=serviceradar-cli-test",
  ])
  const {stdout} = await execFileAsync(
    process.execPath,
    [cliPath.pathname, "--version"],
    {env: {...process.env, HOME: credsHome, XDG_CONFIG_HOME: credsHome, NODE_EXTRA_CA_CERTS: ""}},
  )
  assert.match(stdout, /^@carverauto\/serviceradar-cli \d+\.\d+\.\d+/m)
})

test("auth login falls back to manual token when device endpoint is missing", async () => {
  const credsHome = await mkdtemp(join(tmpdir(), "sr-cli-auth-manual-"))
  // Run a stub HTTP server that 404s the device endpoint to force the fallback.
  const {createServer} = await import("node:http")
  const server = createServer((req, res) => {
    res.writeHead(404, {"content-type": "application/json"})
    res.end(JSON.stringify({error: "device-code endpoint not implemented"}))
  })
  await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen))
  const port = server.address().port
  const instance = `http://127.0.0.1:${port}`

  try {
    const {stderr} = await execFileAsync(
      process.execPath,
      [cliPath.pathname, "auth", "login", "--instance", instance, "--no-browser", "--token", "manual-token-abc"],
      {env: {...process.env, HOME: credsHome, XDG_CONFIG_HOME: credsHome, SERVICERADAR_TOKEN: ""}},
    )
    assert.match(stderr, /Device-code login is not available/)
    assert.match(stderr, /Falling back to manual token entry/)

    // The token should have been persisted to the credentials store.
    const credsPath = join(credsHome, "serviceradar", "credentials.json")
    const stored = JSON.parse(await readFile(credsPath, "utf8"))
    assert.equal(stored.instances?.[instance]?.token, "manual-token-abc")
  } finally {
    await new Promise((resolveClose) => server.close(resolveClose))
  }
})

test("auth status prints stored instance metadata without the token", async () => {
  const credsHome = await mkdtemp(join(tmpdir(), "sr-cli-auth-status-"))
  await execFileAsync("mkdir", ["-p", join(credsHome, "serviceradar")])
  await writeFile(join(credsHome, "serviceradar", "credentials.json"), JSON.stringify({
    version: 1,
    instances: {
      "https://serviceradar.example.com": {
        token: "secret-token-do-not-leak",
        user: "alice@example.com",
        obtained_at: "2026-05-04T20:30:00Z",
        expires_at: "2026-08-04T20:30:00Z",
      },
    },
  }, null, 2))

  const {stdout} = await execFileAsync(
    process.execPath,
    [cliPath.pathname, "auth", "status"],
    {env: {...process.env, HOME: credsHome, XDG_CONFIG_HOME: credsHome}},
  )

  assert.match(stdout, /Instance: https:\/\/serviceradar\.example\.com/)
  assert.match(stdout, /user:\s+alice@example\.com/)
  assert.match(stdout, /obtained_at: 2026-05-04T20:30:00Z/)
  assert.doesNotMatch(stdout, /secret-token-do-not-leak/)
})

test("auth logout removes a stored credential entry", async () => {
  const credsHome = await mkdtemp(join(tmpdir(), "sr-cli-auth-logout-"))
  await execFileAsync("mkdir", ["-p", join(credsHome, "serviceradar")])
  await writeFile(join(credsHome, "serviceradar", "credentials.json"), JSON.stringify({
    version: 1,
    instances: {"https://serviceradar.example.com": {token: "t"}},
  }, null, 2))

  const {stdout} = await execFileAsync(
    process.execPath,
    [cliPath.pathname, "auth", "logout", "--instance", "https://serviceradar.example.com"],
    {env: {...process.env, HOME: credsHome, XDG_CONFIG_HOME: credsHome}},
  )
  assert.match(stdout, /Removed credential for https:\/\/serviceradar\.example\.com/)

  const stored = JSON.parse(await readFile(join(credsHome, "serviceradar", "credentials.json"), "utf8"))
  assert.equal(stored.instances?.["https://serviceradar.example.com"], undefined)
})
