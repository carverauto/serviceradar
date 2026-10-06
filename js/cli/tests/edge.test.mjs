// Black-box tests for the edge onboarding commands (`agent`, `edge`,
// `collector`, `nats`) and the edge-related `auth login` behaviour.
//
// A canned http server stands in for a hosted tenant and the CLI runs as a
// subprocess, so the tests exercise the shipped bin end to end: what it sends
// to the server, what it prints, and what it writes to disk.

import {execFile} from "node:child_process"
import {createServer} from "node:http"
import {mkdtemp, readFile} from "node:fs/promises"
import {tmpdir} from "node:os"
import {join} from "node:path"
import {promisify} from "node:util"
import test from "node:test"
import assert from "node:assert/strict"

const execFileAsync = promisify(execFile)
const cliRoot = new URL("..", import.meta.url).pathname
const cliPath = join(cliRoot, "bin/serviceradar-cli.js")

async function withServer(handler, run) {
  const requests = []
  const server = createServer(async (req, res) => {
    const chunks = []
    for await (const chunk of req) chunks.push(chunk)
    const raw = Buffer.concat(chunks).toString("utf8")
    const entry = {
      method: req.method,
      path: req.url,
      headers: req.headers,
      body: raw ? safeJson(raw) : null,
    }
    requests.push(entry)
    await handler(entry, res)
  })
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve))
  const {port} = server.address()
  try {
    return await run(`http://127.0.0.1:${port}`, requests)
  } finally {
    await new Promise((resolve) => server.close(resolve))
  }
}

function safeJson(raw) {
  try {
    return JSON.parse(raw)
  } catch {
    return raw
  }
}

function json(res, status, body) {
  res.writeHead(status, {"content-type": "application/json"})
  res.end(JSON.stringify(body))
}

async function freshHome() {
  return mkdtemp(join(tmpdir(), "sr-cli-edge-"))
}

async function runCli(args, {env = {}, cwd, bin = cliPath} = {}) {
  const home = env.HOME || (await freshHome())
  try {
    const {stdout, stderr} = await execFileAsync(process.execPath, [bin, ...args], {
      cwd,
      env: {...process.env, HOME: home, XDG_CONFIG_HOME: home, SERVICERADAR_TOKEN: "", SERVICERADAR_INSTANCE: "", ...env},
    })
    return {code: 0, stdout, stderr}
  } catch (error) {
    return {code: error.code ?? 1, stdout: error.stdout || "", stderr: error.stderr || ""}
  }
}

const TOKEN_ENV = {SERVICERADAR_TOKEN: "operator-bearer"}

function edgepkgToken(packageId) {
  const payload = Buffer.from(JSON.stringify({pkg: packageId, dl: "dl-secret", partition_id: "default"})).toString("base64url")
  return `edgepkg-v3:${payload}.c2lnbmF0dXJl`
}

// ------------------------------------------------------------------ auth

async function runDeviceLogin(instance, extraArgs = []) {
  const home = await freshHome()
  const result = await runCli(["auth", "login", "--instance", instance, "--no-browser", ...extraArgs], {env: {HOME: home}})
  return {...result, home}
}

function deviceFlowServer(captured) {
  return (req, res) => {
    if (req.path === "/api/v1/cli/auth/device") {
      captured.deviceBody = req.body
      return json(res, 200, {device_code: "dev-1", user_code: "ABCD-EFGH", verification_uri: "http://example/cli", interval: 1, expires_in: 60})
    }
    if (req.path === "/api/v1/cli/auth/token") {
      return json(res, 200, {access_token: "issued-token", user: "ops@example.com", scope: captured.deviceBody?.scope})
    }
    return json(res, 404, {})
  }
}

test("auth login requests the edge.manage scope by default and records it", async () => {
  const captured = {}
  await withServer(deviceFlowServer(captured), async (instance) => {
    const {code, stderr, home} = await runDeviceLogin(instance)
    assert.equal(code, 0, stderr)
    assert.equal(captured.deviceBody.scope, "dashboard.publish edge.manage")

    const status = await runCli(["auth", "status"], {env: {HOME: home}})
    assert.match(status.stdout, /scope:\s+dashboard\.publish edge\.manage/)
  })
})

test("auth login --scope overrides the defaults and normalises commas to spaces", async () => {
  // The server stores the scope string verbatim and confines tokens by
  // splitting it on whitespace, so a comma-joined value would be one bogus scope.
  const captured = {}
  await withServer(deviceFlowServer(captured), async (instance) => {
    const {code, stderr} = await runDeviceLogin(instance, ["--scope", "plugin.publish,plugins.manage"])
    assert.equal(code, 0, stderr)
    assert.equal(captured.deviceBody.scope, "plugin.publish plugins.manage")
  })
})

test("auth login explains a server policy that refuses edge.manage instead of falling back", async () => {
  await withServer(
    (req, res) => json(res, 400, {error: "invalid_scope", error_description: "Requested scope is not allowed"}),
    async (instance) => {
      const {code, stderr, home} = await runDeviceLogin(instance, ["--token", "would-be-pasted"])
      assert.notEqual(code, 0)
      assert.match(stderr, /does not allow edge\.manage/)
      assert.match(stderr, /--scope dashboard\.publish/)
      assert.doesNotMatch(stderr, /Falling back to manual token entry/)
      await assert.rejects(readFile(join(home, "serviceradar", "credentials.json"), "utf8"))
    },
  )
})

// ------------------------------------------------------------------ errors

test("a token without edge.manage gets told to re-run auth login", async () => {
  await withServer(
    (req, res) => json(res, 403, {error: "insufficient_scope", message: "token scope does not permit this endpoint", granted: ["dashboard.publish"]}),
    async (instance) => {
      const {code, stderr} = await runCli(["edge", "site", "list", "--instance", instance], {env: TOKEN_ENV})
      assert.notEqual(code, 0)
      assert.match(stderr, /HTTP 403/)
      assert.match(stderr, /does not carry the edge\.manage scope \(it holds: dashboard\.publish\)/)
      assert.match(stderr, new RegExp(`auth login --instance ${instance.replace(/[.]/g, "\\.")}`))
    },
  )
})

test("a rejected token (401) gets told to log in again, and RBAC 403 names the permission", async () => {
  await withServer(
    (req, res) => (req.path.startsWith("/api/admin/collectors")
      ? json(res, 403, {errors: {detail: "Forbidden"}})
      : json(res, 401, {errors: {detail: "Unauthorized"}})),
    async (instance) => {
      const unauthorized = await runCli(["nats", "account", "status", "--instance", instance], {env: TOKEN_ENV})
      assert.notEqual(unauthorized.code, 0)
      assert.match(unauthorized.stderr, /HTTP 401 — the server rejected your token/)
      assert.match(unauthorized.stderr, /re-run `serviceradar-cli auth login/)

      const forbidden = await runCli(["collector", "list", "--instance", instance], {env: TOKEN_ENV})
      assert.notEqual(forbidden.code, 0)
      assert.match(forbidden.stderr, /settings\.edge\.manage permission/)
    },
  )
})

test("edge commands refuse to run without any credential and name the login command", async () => {
  const {code, stderr} = await runCli(["agent", "list", "--instance", "https://tenant.example"])
  assert.notEqual(code, 0)
  assert.match(stderr, /no token resolved for https:\/\/tenant\.example/)
  assert.match(stderr, /auth login --instance https:\/\/tenant\.example/)
})

// ------------------------------------------------------------------ agents

test("agent list falls back to the JSON:API route and normalises its rows", async () => {
  await withServer(
    (req, res) => {
      if (req.path === "/api/admin/agents") return json(res, 404, {errors: {detail: "Not Found"}})
      if (req.path === "/api/v2/agents") {
        return json(res, 200, {
          data: [{
            id: "agent-edge-1",
            type: "agent",
            attributes: {name: "edge-1", gateway_id: "gw-1", status: "connected", last_seen_time: "2026-10-03T10:00:00Z", version: "1.4.81"},
          }],
        })
      }
      return json(res, 500, {})
    },
    async (instance, requests) => {
      const {code, stdout, stderr} = await runCli(["agent", "list", "--instance", instance, "--json"], {env: TOKEN_ENV})
      assert.equal(code, 0, stderr)
      assert.deepEqual(JSON.parse(stdout), [{
        uid: "agent-edge-1",
        name: "edge-1",
        gateway_id: "gw-1",
        status: "connected",
        last_seen: "2026-10-03T10:00:00Z",
        version: "1.4.81",
        partition: "",
      }])
      assert.equal(requests.at(-1).headers.authorization, "Bearer operator-bearer")
    },
  )
})

test("agent list prints a table from the admin route", async () => {
  await withServer(
    (req, res) => json(res, 200, {data: [{uid: "agent-a", name: "a", gateway_id: "gw", status: "connected", last_seen: "now", version: "1.4.81", partition: "default"}]}),
    async (instance) => {
      const {code, stdout} = await runCli(["agent", "list", "--instance", instance], {env: TOKEN_ENV})
      assert.equal(code, 0)
      const [header, row] = stdout.trim().split("\n")
      assert.deepEqual(header.split(/\s{2,}/), ["UID", "NAME", "GATEWAY", "STATUS", "LAST SEEN", "VERSION", "PARTITION"])
      assert.deepEqual(row.split(/\s{2,}/), ["agent-a", "a", "gw", "connected", "now", "1.4.81", "default"])
    },
  )
})

// ------------------------------------------------------------------ edge packages

test("edge package create sends the UI-equivalent payload and prints the onboarding token", async () => {
  const token = edgepkgToken("pkg-1")
  await withServer(
    (req, res) => json(res, 201, {
      package: {package_id: "pkg-1", label: "Branch Office 1", component_id: "agent-branch-office-1", component_type: "agent", status: "issued", site: "branch"},
      join_token: "join",
      download_token: "dl",
      onboarding_token: token,
      bundle_pem: "",
    }),
    async (instance, requests) => {
      const {code, stdout, stderr} = await runCli(
        ["edge", "package", "create", "--instance", instance, "--label", "Branch Office 1", "--component-type", "agent", "--site", "branch", "--gateway-id", "gw-1"],
        {env: TOKEN_ENV},
      )
      assert.equal(code, 0, stderr)
      const [request] = requests
      assert.equal(request.method, "POST")
      assert.equal(request.path, "/api/admin/edge-packages")
      assert.deepEqual(request.body, {
        label: "Branch Office 1",
        component_type: "agent",
        component_id: "agent-branch-office-1",
        security_mode: "mtls",
        gateway_id: "gw-1",
        site: "branch",
        parent_type: "gateway",
        metadata_json: JSON.stringify({partition: "branch"}),
      })
      assert.match(stdout, /Created agent package pkg-1/)
      assert.ok(stdout.includes(token))
      assert.match(stdout, /edge install agent --instance .* --package pkg-1/)

      const asJson = await runCli(["edge", "package", "create", "--instance", instance, "--label", "x", "--json"], {env: TOKEN_ENV})
      const parsed = JSON.parse(asJson.stdout)
      assert.equal(parsed.package.package_id, "pkg-1")
      assert.equal(parsed.onboarding_token, token)
    },
  )
})

test("edge package create warns when the server returns no signed onboarding token", async () => {
  await withServer(
    (req, res) => json(res, 201, {package: {package_id: "pkg-2", component_type: "agent"}, join_token: "j", download_token: "d"}),
    async (instance) => {
      const {code, stderr} = await runCli(["edge", "package", "create", "--instance", instance, "--label", "x"], {env: TOKEN_ENV})
      assert.equal(code, 0)
      assert.match(stderr, /did not return a signed onboarding token/)
    },
  )
})

test("edge package create rejects an unknown component type before calling the server", async () => {
  await withServer(
    (req, res) => json(res, 500, {}),
    async (instance, requests) => {
      const {code, stderr} = await runCli(["edge", "package", "create", "--instance", instance, "--label", "x", "--component-type", "router"], {env: TOKEN_ENV})
      assert.notEqual(code, 0)
      assert.match(stderr, /--component-type must be one of: agent, gateway, checker, sync/)
      assert.equal(requests.length, 0)
    },
  )
})

test("edge package list/show/revoke hit the EdgeController routes", async () => {
  const pkg = {package_id: "pkg-1", label: "edge", component_type: "agent", status: "issued", site: "default", created_at: "2026-10-01T00:00:00Z"}
  await withServer(
    (req, res) => {
      if (req.method === "GET" && req.path.startsWith("/api/admin/edge-packages?")) return json(res, 200, [pkg])
      if (req.method === "GET" && req.path === "/api/admin/edge-packages/pkg-1") return json(res, 200, pkg)
      if (req.method === "POST" && req.path === "/api/admin/edge-packages/pkg-1/revoke") return json(res, 200, {...pkg, status: "revoked"})
      return json(res, 404, {errors: {detail: "Not Found"}})
    },
    async (instance, requests) => {
      const list = await runCli(["edge", "package", "list", "--instance", instance, "--status", "issued", "--json"], {env: TOKEN_ENV})
      assert.deepEqual(JSON.parse(list.stdout), [pkg])
      assert.equal(requests[0].path, "/api/admin/edge-packages?status=issued")

      const show = await runCli(["edge", "package", "show", "pkg-1", "--instance", instance], {env: TOKEN_ENV})
      assert.match(show.stdout, /Edge package pkg-1/)
      assert.match(show.stdout, /status:\s+issued/)

      const revoke = await runCli(["edge", "package", "revoke", "pkg-1", "--instance", instance, "--reason", "host retired"], {env: TOKEN_ENV})
      assert.equal(revoke.code, 0, revoke.stderr)
      assert.deepEqual(requests.at(-1).body, {reason: "host retired"})

      const missing = await runCli(["edge", "package", "show", "nope", "--instance", instance], {env: TOKEN_ENV})
      assert.notEqual(missing.code, 0)
      assert.match(missing.stderr, /HTTP 404/)
    },
  )
})

test("edge package download sends only the onboarding token and writes the bundle to -o", async () => {
  const tarball = Buffer.from("fake-gzip-bytes")
  await withServer(
    (req, res) => {
      res.writeHead(200, {"content-type": "application/gzip", "content-disposition": 'attachment; filename="../../etc/evil.tar.gz"'})
      res.end(tarball)
    },
    async (instance, requests) => {
      const dir = await freshHome()
      const out = join(dir, "pkg.tar.gz")
      const {code, stderr} = await runCli(["edge", "package", "download", "pkg-1", "--instance", instance, "--token", "edgepkg-v3:abc.def", "-o", out])
      assert.equal(code, 0, stderr)
      assert.deepEqual(await readFile(out), tarball)
      const [request] = requests
      assert.equal(request.path, "/api/edge-packages/pkg-1/bundle")
      assert.equal(request.headers["x-serviceradar-download-token"], "edgepkg-v3:abc.def")
      assert.equal(request.headers.authorization, undefined)

      // Without -o the server's filename is used, stripped to its basename.
      const cwd = await freshHome()
      const second = await runCli(["edge", "package", "download", "pkg-1", "--instance", instance, "--token", "t", "--json"], {cwd})
      assert.match(JSON.parse(second.stdout).path, /\/sr-cli-edge-[^/]+\/evil\.tar\.gz$/)
      assert.deepEqual(await readFile(join(cwd, "evil.tar.gz")), tarball)
    },
  )
})

test("edge package download explains an already-delivered package", async () => {
  await withServer(
    (req, res) => json(res, 409, {error: "package already_delivered"}),
    async (instance) => {
      const {code, stderr} = await runCli(["edge", "package", "download", "pkg-1", "--instance", instance, "--token", "t"])
      assert.notEqual(code, 0)
      assert.match(stderr, /HTTP 409 — package already_delivered/)
      assert.match(stderr, /create a new one/)
    },
  )
})

// ------------------------------------------------------------------ edge sites

const SITE = {id: "site-1", name: "Branch 1", slug: "branch-1", status: "active", nats_leaf_url: "tls://leaf", leaf_server: {status: "ready", upstream_url: "tls://t.nats:7422"}, inserted_at: "2026-10-03T00:00:00Z"}

test("edge site create/list/show use the edge-sites contract", async () => {
  await withServer(
    (req, res) => {
      if (req.method === "POST" && req.path === "/api/admin/edge-sites") return json(res, 201, {data: {...SITE, leaf_server: null}})
      if (req.method === "GET" && req.path === "/api/admin/edge-sites") return json(res, 200, {data: [SITE]})
      if (req.method === "GET" && req.path === "/api/admin/edge-sites/site-1") return json(res, 200, {data: SITE})
      return json(res, 404, {})
    },
    async (instance, requests) => {
      const created = await runCli(["edge", "site", "create", "--instance", instance, "--name", "Branch 1", "--slug", "branch-1", "--json"], {env: TOKEN_ENV})
      assert.equal(created.code, 0, created.stderr)
      assert.deepEqual(requests[0].body, {name: "Branch 1", slug: "branch-1"})
      assert.equal(JSON.parse(created.stdout).id, "site-1")

      const list = await runCli(["edge", "site", "list", "--instance", instance], {env: TOKEN_ENV})
      const rows = list.stdout.trim().split("\n").map((line) => line.split(/\s{2,}/))
      assert.deepEqual(rows[0], ["ID", "NAME", "SLUG", "STATUS", "LEAF", "CREATED"])
      assert.deepEqual(rows[1], ["site-1", "Branch 1", "branch-1", "active", "ready", "2026-10-03T00:00:00Z"])

      const show = await runCli(["edge", "site", "show", "site-1", "--instance", instance, "--json"], {env: TOKEN_ENV})
      assert.deepEqual(JSON.parse(show.stdout), SITE)
    },
  )
})

test("edge site bundle fails with a --wait hint while the leaf is not ready", async () => {
  await withServer(
    (req, res) => json(res, 409, {error: "leaf_not_ready"}),
    async (instance) => {
      const {code, stderr} = await runCli(["edge", "site", "bundle", "site-1", "--instance", instance], {env: TOKEN_ENV})
      assert.notEqual(code, 0)
      assert.match(stderr, /not provisioned yet \(HTTP 409 leaf_not_ready\)/)
      assert.match(stderr, /re-run with --wait/)
    },
  )
})

test("edge site bundle --wait polls through leaf_not_ready and saves the bundle", async () => {
  let attempts = 0
  await withServer(
    (req, res) => {
      attempts += 1
      if (attempts < 3) return json(res, 409, {error: "leaf_not_ready"})
      res.writeHead(200, {"content-type": "application/gzip", "content-disposition": 'attachment; filename="edge-site-branch-1.tar.gz"'})
      res.end("leaf-bundle")
    },
    async (instance, requests) => {
      const cwd = await freshHome()
      const {code, stdout, stderr} = await runCli(
        ["edge", "site", "bundle", "site-1", "--instance", instance, "--wait", "--interval", "0.05", "--timeout", "10"],
        {env: TOKEN_ENV, cwd},
      )
      assert.equal(code, 0, stderr)
      assert.equal(attempts, 3)
      assert.ok(requests.every((r) => r.method === "POST" && r.path === "/api/admin/edge-sites/site-1/bundle"))
      assert.match(stderr, /waiting for the leaf server/)
      assert.match(stdout, /Wrote leaf bundle/)
      assert.equal(await readFile(join(cwd, "edge-site-branch-1.tar.gz"), "utf8"), "leaf-bundle")
    },
  )
})

test("edge site bundle --wait gives up at --timeout", async () => {
  await withServer(
    (req, res) => json(res, 409, {error: "leaf_not_ready"}),
    async (instance) => {
      const {code, stderr} = await runCli(
        ["edge", "site", "bundle", "site-1", "--instance", instance, "--wait", "--interval", "0.05", "--timeout", "0.2"],
        {env: TOKEN_ENV},
      )
      assert.notEqual(code, 0)
      assert.match(stderr, /still not ready after 0\.2s/)
    },
  )
})

// ------------------------------------------------------------------ collectors + nats

test("collector create targets an edge site and prints the enrollment token", async () => {
  await withServer(
    (req, res) => json(res, 201, {id: "col-1", collector_type: "sflow", status: "pending", edge_site_id: "site-1", enrollment_token: "collectorpkg-v2:xyz"}),
    async (instance, requests) => {
      const {code, stdout, stderr} = await runCli(["collector", "create", "--instance", instance, "--type", "sflow", "--edge-site", "site-1"], {env: TOKEN_ENV})
      assert.equal(code, 0, stderr)
      assert.deepEqual(requests[0].body, {collector_type: "sflow", edge_site_id: "site-1"})
      assert.match(stdout, /Created sflow collector col-1/)
      assert.match(stdout, /collectorpkg-v2:xyz/)
      assert.match(stdout, /edge install collector --instance .* --id col-1/)
    },
  )
})

test("collector create rejects types the edge host cannot run", async () => {
  const {code, stderr} = await runCli(["collector", "create", "--instance", "https://t.example", "--type", "falcosidekick"], {env: TOKEN_ENV})
  assert.notEqual(code, 0)
  assert.match(stderr, /--type is required and must be one of: flowgger, trapd, netflow, sflow, otel/)
})

test("collector list/show/revoke and download round-trip", async () => {
  const pkg = {id: "col-1", collector_type: "trapd", status: "ready", site: "branch", edge_site: {slug: "branch-1", nats_leaf_url: "tls://leaf"}}
  await withServer(
    (req, res) => {
      if (req.method === "GET" && req.path === "/api/admin/collectors") return json(res, 200, [pkg])
      if (req.method === "GET" && req.path === "/api/admin/collectors/col-1") return json(res, 200, pkg)
      if (req.method === "POST" && req.path === "/api/admin/collectors/col-1/revoke") return json(res, 200, {...pkg, status: "revoked"})
      if (req.method === "POST" && req.path === "/api/collectors/col-1/bundle") {
        res.writeHead(200, {"content-type": "application/gzip"})
        return res.end("collector-bundle")
      }
      return json(res, 404, {})
    },
    async (instance, requests) => {
      const list = await runCli(["collector", "list", "--instance", instance, "--json"], {env: TOKEN_ENV})
      assert.deepEqual(JSON.parse(list.stdout), [pkg])

      const show = await runCli(["collector", "show", "col-1", "--instance", instance], {env: TOKEN_ENV})
      assert.match(show.stdout, /edge site:\s+branch-1/)

      const revoke = await runCli(["collector", "revoke", "col-1", "--instance", instance, "--json"], {env: TOKEN_ENV})
      assert.equal(JSON.parse(revoke.stdout).status, "revoked")

      const download = await runCli(["collector", "download", "col-1", "--instance", instance, "--token", "collectorpkg-v2:xyz", "-o", "-"])
      assert.equal(download.code, 0, download.stderr)
      assert.equal(download.stdout, "collector-bundle")
      assert.equal(requests.at(-1).headers["x-serviceradar-download-token"], "collectorpkg-v2:xyz")
    },
  )
})

test("nats account status renders the deployment's NATS account", async () => {
  const status = {status: "ready", nats_url: "tls://t.nats:4222", account_public_key: "ACCOUNTKEY"}
  await withServer(
    (req, res) => (req.path === "/api/admin/nats/account" ? json(res, 200, status) : json(res, 404, {})),
    async (instance) => {
      const human = await runCli(["nats", "account", "status", "--instance", instance], {env: TOKEN_ENV})
      assert.equal(human.code, 0, human.stderr)
      assert.match(human.stdout, /nats url:\s+tls:\/\/t\.nats:4222/)
      const asJson = await runCli(["nats", "account", "status", "--instance", instance, "--json"], {env: TOKEN_ENV})
      assert.deepEqual(JSON.parse(asJson.stdout), status)
    },
  )
})

// ------------------------------------------------------------------ install helpers

const DRY = ["--dry-run", "--format", "rpm", "--arch", "x86_64"]

test("edge install agent --dry-run plans the release RPM, dnf, and srctl enroll without leaking the token", async () => {
  const token = edgepkgToken("pkg-1")
  const {code, stdout, stderr} = await runCli(
    ["edge", "install", "agent", "--instance", "https://tenant.example", "--package", "pkg-1", "--token", token, "--version", "v1.4.81", ...DRY],
  )
  assert.equal(code, 0, stderr)
  assert.match(stdout, /download https:\/\/github\.com\/carverauto\/serviceradar\/releases\/download\/v1\.4\.81\/serviceradar-agent-1\.4\.81-1\.x86_64\.rpm/)
  assert.match(stdout, /run: dnf install -y \S+serviceradar-agent-1\.4\.81-1\.x86_64\.rpm/)
  assert.match(stdout, /run: \/usr\/local\/bin\/srctl enroll --core-url https:\/\/tenant\.example --token <token>/)
  assert.match(stdout, /systemctl restart serviceradar-agent\.service/)
  assert.ok(!stdout.includes(token), "the onboarding token must not be printed")
  assert.match(stdout, /nothing was changed/)
})

test("edge install agent maps deb hosts and arm64 to the matching release asset", async () => {
  const {stdout} = await runCli(
    ["edge", "install", "agent", "--instance", "https://t.example", "--package", "p", "--token", "t", "--version", "1.4.81", "--dry-run", "--format", "deb", "--arch", "arm64"],
  )
  assert.match(stdout, /v1\.4\.81\/serviceradar-agent_1\.4\.81_arm64\.deb/)
  assert.match(stdout, /run: apt-get install -y /)
})

test("edge install agent refuses a token issued for another package", async () => {
  const {code, stderr} = await runCli(
    ["edge", "install", "agent", "--instance", "https://t.example", "--package", "pkg-1", "--token", edgepkgToken("pkg-2"), "--version", "1.4.81", ...DRY],
  )
  assert.notEqual(code, 0)
  assert.match(stderr, /--token belongs to edge package pkg-2, not --package pkg-1/)
})

test("edge install agent requires --version", async () => {
  const {code, stderr} = await runCli(
    ["edge", "install", "agent", "--instance", "https://t.example", "--package", "p", "--token", "t", ...DRY],
  )
  assert.notEqual(code, 0)
  assert.match(stderr, /--version is required/)
})

test("edge install refuses to change the host unless run as root", {skip: process.getuid?.() === 0}, async () => {
  const {code, stderr} = await runCli(
    ["edge", "install", "agent", "--instance", "https://t.example", "--package", "p", "--token", "t", "--version", "1.4.81"],
  )
  assert.notEqual(code, 0)
  assert.match(stderr, /must run as root/)
})

test("edge install collector --dry-run picks the package for the collector's type", async () => {
  await withServer(
    (req, res) => (req.path === "/api/admin/collectors/col-1"
      ? json(res, 200, {id: "col-1", collector_type: "sflow", status: "ready"})
      : json(res, 404, {})),
    async (instance, requests) => {
      const {code, stdout, stderr} = await runCli(
        ["edge", "install", "collector", "--instance", instance, "--id", "col-1", "--token", "collectorpkg-v2:x", "--version", "1.4.81", ...DRY],
        {env: TOKEN_ENV},
      )
      assert.equal(code, 0, stderr)
      assert.match(stdout, /serviceradar-flow-collector-1\.4\.81-1\.x86_64\.rpm/)
      assert.match(stdout, /POST .*\/api\/collectors\/col-1\/bundle/)
      assert.match(stdout, /run update\.sh from the extracted bundle in \/etc\/serviceradar\/collectors\/col-1/)
      // The dry run only reads: it must not consume the collector bundle.
      assert.deepEqual(requests.map((r) => `${r.method} ${r.path}`), ["GET /api/admin/collectors/col-1"])
    },
  )
})

function latestRelease(names) {
  return {tag_name: "v9.9.9", assets: names.map((name) => ({name}))}
}

const LATEST_PACKAGES = [
  "serviceradar-nats-9.9.9-1.x86_64.rpm",
  "serviceradar-nats-9.9.9-1.aarch64.rpm",
  "serviceradar-nats_9.9.9_amd64.deb",
  "serviceradar-flow-collector-9.9.9-1.x86_64.rpm",
  "serviceradar-log-collector-9.9.9-1.x86_64.rpm",
  "serviceradar-trapd-9.9.9-1.x86_64.rpm",
  "serviceradar-agent-9.9.9-1.x86_64.rpm",
]

test("edge install leaf without --version downloads the latest serviceradar-nats asset", async () => {
  await withServer(
    (req, res) => {
      if (req.path === "/api/admin/edge-sites/site-1") return json(res, 200, {data: SITE})
      if (req.path === "/github/releases/latest") return json(res, 200, latestRelease(LATEST_PACKAGES))
      return json(res, 404, {})
    },
    async (instance, requests) => {
      const ok = await runCli(
        ["edge", "install", "leaf", "--instance", instance, "--site", "site-1", "--release-api-url", `${instance}/github/releases/latest`, ...DRY],
        {env: TOKEN_ENV},
      )
      assert.equal(ok.code, 0, ok.stderr)
      assert.match(ok.stdout, /download https:\/\/github\.com\/carverauto\/serviceradar\/releases\/download\/v9\.9\.9\/serviceradar-nats-9\.9\.9-1\.x86_64\.rpm/)
      assert.equal(ok.stdout.includes("serviceradar-agent-9.9.9"), false)
      assert.equal(ok.stdout.includes("serviceradar-nats_9.9.9_amd64.deb"), false)
      const setup = ok.stdout.indexOf("setup.sh")
      const confirm = ok.stdout.indexOf("confirm the local NATS leaf is active")
      assert.ok(setup !== -1 && confirm > setup, ok.stdout)
      assert.ok(requests.some((request) => request.path === "/github/releases/latest"))

      const missing = await runCli(
        ["edge", "install", "leaf", "--instance", instance, "--site", "site-1", "--release-api-url", `${instance}/github/releases/latest`, "--dry-run", "--format", "deb", "--arch", "arm64"],
        {env: TOKEN_ENV},
      )
      assert.notEqual(missing.code, 0)
      assert.match(missing.stderr, /no serviceradar-nats deb package for arm64/)
    },
  )
})

test("edge install collector without --version uses the latest package and waits for the local leaf", async () => {
  await withServer(
    (req, res) => {
      if (req.path === "/api/admin/collectors/col-1") {
        return json(res, 200, {
          id: "col-1",
          collector_type: "netflow",
          status: "ready",
          edge_site_id: "site-1",
          edge_site: {slug: "branch-1", nats_url: "tls://127.0.0.1:4222"},
        })
      }
      if (req.path === "/api/admin/collectors/col-2") {
        return json(res, 200, {id: "col-2", collector_type: "flowgger", status: "ready"})
      }
      if (req.path === "/github/releases/latest") return json(res, 200, latestRelease(LATEST_PACKAGES))
      return json(res, 404, {})
    },
    async (instance) => {
      const bound = await runCli(
        ["edge", "install", "collector", "--instance", instance, "--id", "col-1", "--token", "collectorpkg-v2:x", "--release-api-url", `${instance}/github/releases/latest`, ...DRY],
        {env: TOKEN_ENV},
      )
      assert.equal(bound.code, 0, bound.stderr)
      assert.match(bound.stdout, /serviceradar-flow-collector-9\.9\.9-1\.x86_64\.rpm/)
      const confirm = bound.stdout.indexOf("confirm the local NATS leaf is active")
      const bundle = bound.stdout.indexOf("/api/collectors/col-1/bundle")
      assert.ok(confirm !== -1 && bundle !== -1 && confirm < bundle, bound.stdout)
      assert.match(bound.stdout, /writes to tls:\/\/127\.0\.0\.1:4222/)

      const unbound = await runCli(
        ["edge", "install", "collector", "--instance", instance, "--id", "col-2", "--token", "collectorpkg-v2:x", "--release-api-url", `${instance}/github/releases/latest`, ...DRY],
        {env: TOKEN_ENV},
      )
      assert.equal(unbound.code, 0, unbound.stderr)
      assert.match(unbound.stdout, /serviceradar-log-collector-9\.9\.9-1\.x86_64\.rpm/)
      assert.equal(unbound.stdout.includes("confirm the local NATS leaf"), false)
    },
  )
})

test("edge install leaf --dry-run checks the site exists and plans NATS + setup.sh", async () => {
  await withServer(
    (req, res) => (req.path === "/api/admin/edge-sites/site-1" ? json(res, 200, {data: SITE}) : json(res, 404, {errors: {detail: "Not Found"}})),
    async (instance, requests) => {
      const ok = await runCli(["edge", "install", "leaf", "--instance", instance, "--site", "site-1", "--version", "1.4.81", ...DRY], {env: TOKEN_ENV})
      assert.equal(ok.code, 0, ok.stderr)
      assert.match(ok.stdout, /leaf status: ready/)
      assert.match(ok.stdout, /serviceradar-nats-1\.4\.81-1\.x86_64\.rpm/)
      assert.match(ok.stdout, /run setup\.sh from the extracted bundle in \/etc\/serviceradar\/edge-sites\/site-1/)
      assert.deepEqual(requests.map((r) => `${r.method} ${r.path}`), ["GET /api/admin/edge-sites/site-1"])

      const missing = await runCli(["edge", "install", "leaf", "--instance", instance, "--site", "nope", "--version", "1.4.81", ...DRY], {env: TOKEN_ENV})
      assert.notEqual(missing.code, 0)
      assert.match(missing.stderr, /HTTP 404/)
    },
  )
})

// ------------------------------------------------------------------ bin alias

test("the package declares a srcloud bin that runs this CLI", async () => {
  const pkg = JSON.parse(await readFile(join(cliRoot, "package.json"), "utf8"))
  assert.ok(pkg.bin.srcloud, "package.json must declare a srcloud bin")
  const {code, stdout} = await runCli(["--version"], {bin: join(cliRoot, pkg.bin.srcloud)})
  assert.equal(code, 0)
  assert.match(stdout, new RegExp(`^@carverauto/serviceradar-cli ${pkg.version.replace(/\./g, "\\.")}`, "m"))
})
