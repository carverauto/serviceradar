// Black-box tests for `serviceradar-cli dashboard publish` error envelopes.
//
// We spin up a tiny http server that returns a canned response shaped like
// the controller's structured error envelope, then run the CLI subprocess
// against it. The assertion is that the CLI's printed error message
// contains the actionable hint specific to that error code — covers the
// errorHint() table in src/dashboard/publish.ts without needing to import
// from a dist/ ESM module that isn't published.

import {execFile} from "node:child_process"
import {createHash} from "node:crypto"
import {createServer} from "node:http"
import {mkdir, mkdtemp, writeFile} from "node:fs/promises"
import {tmpdir} from "node:os"
import {join} from "node:path"
import {promisify} from "node:util"
import test from "node:test"
import assert from "node:assert/strict"

const execFileAsync = promisify(execFile)
const cliPath = new URL("../bin/serviceradar-cli.js", import.meta.url).pathname

async function buildProject() {
  const projectDir = await mkdtemp(join(tmpdir(), "sr-pub-err-"))
  await mkdir(join(projectDir, "dist"), {recursive: true})

  const rendererBytes = "export default {mount(){},destroy(){}}"
  const sha256 = createHash("sha256").update(rendererBytes).digest("hex")

  const manifest = {
    schema_version: 1,
    id: "com.example.errtest",
    name: "Error Test",
    version: "0.1.0",
    renderer: {
      kind: "browser_module",
      interface_version: "dashboard-browser-module-v1",
      artifact: "renderer.js",
      sha256,
      trust: "trusted",
    },
    data_frames: [{id: "f1", query: "in:wifi_sites limit:1", encoding: "json_rows"}],
    capabilities: ["srql.execute"],
  }

  await writeFile(join(projectDir, "dist", "renderer.js"), rendererBytes)
  await writeFile(join(projectDir, "dist", "manifest.json"), JSON.stringify(manifest))

  // Minimal dashboard.config.mjs — loadConfig accepts ESM exports.
  await writeFile(
    join(projectDir, "dashboard.config.mjs"),
    `export default {
       manifest: ${JSON.stringify(manifest)},
       samples: {frames: "frames.json", settings: "settings.json"},
     }`,
  )
  await writeFile(join(projectDir, "frames.json"), JSON.stringify([{id: "f1", results: []}]))
  await writeFile(join(projectDir, "settings.json"), JSON.stringify({}))

  return projectDir
}

function startServer(handler) {
  return new Promise((resolveSetup) => {
    const srv = createServer(async (req, res) => {
      try {
        await handler(req, res)
      } catch (err) {
        res.statusCode = 500
        res.end(String(err))
      }
    })
    srv.listen(0, "127.0.0.1", () => {
      const port = srv.address().port
      resolveSetup({srv, port, instance: `http://127.0.0.1:${port}`})
    })
  })
}

async function runPublish({instance, route, expectError = true} = {}) {
  const projectDir = await buildProject()
  const args = [
    cliPath,
    "dashboard",
    "publish",
    "--instance",
    instance,
    "--token",
    "fake-jwt-for-testing",
    "--yes",
  ]
  if (route !== undefined) args.push("--route", route)
  if (expectError) {
    try {
      const result = await execFileAsync(process.execPath, args, {cwd: projectDir})
      return {ok: true, stdout: result.stdout, stderr: result.stderr}
    } catch (err) {
      return {ok: false, code: err.code, stdout: err.stdout || "", stderr: err.stderr || ""}
    }
  }
  const result = await execFileAsync(process.execPath, args, {cwd: projectDir})
  return {ok: true, stdout: result.stdout, stderr: result.stderr}
}

function jsonReply(res, status, body, extraHeaders = {}) {
  res.statusCode = status
  res.setHeader("content-type", "application/json")
  for (const [k, v] of Object.entries(extraHeaders)) res.setHeader(k, v)
  res.end(JSON.stringify(body))
}

test("insufficient_scope envelope surfaces the auth login hint", async () => {
  const {srv, instance} = await startServer((req, res) => {
    jsonReply(res, 403, {error: "insufficient_scope", required: "dashboard.publish"})
  })
  try {
    const r = await runPublish({instance, route: "x"})
    assert.equal(r.ok, false)
    const out = `${r.stdout}\n${r.stderr}`
    assert.match(out, /insufficient_scope/)
    assert.match(out, /serviceradar-cli auth login/)
  } finally {
    srv.close()
  }
})

test("forbidden envelope surfaces the missing-permission hint", async () => {
  const {srv, instance} = await startServer((req, res) => {
    jsonReply(res, 403, {error: "forbidden", permission: "cli.dashboard.publish"})
  })
  try {
    const r = await runPublish({instance, route: "x"})
    assert.equal(r.ok, false)
    const out = `${r.stdout}\n${r.stderr}`
    assert.match(out, /forbidden/)
    assert.match(out, /missing the "cli\.dashboard\.publish" permission/)
  } finally {
    srv.close()
  }
})

test("slug_in_use envelope surfaces the owner_dashboard_id and a fix hint", async () => {
  const {srv, instance} = await startServer((req, res) => {
    jsonReply(res, 409, {
      error: "slug_in_use",
      route: "wifi-network-map",
      owner_dashboard_id: "com.example.network-map",
    })
  })
  try {
    const r = await runPublish({instance, route: "wifi-network-map"})
    assert.equal(r.ok, false)
    const out = `${r.stdout}\n${r.stderr}`
    assert.match(out, /slug_in_use/)
    assert.match(out, /com\.example\.network-map/)
    assert.match(out, /pick a different --route/)
  } finally {
    srv.close()
  }
})

test("version_already_published envelope surfaces the existing content_hash", async () => {
  const {srv, instance} = await startServer((req, res) => {
    jsonReply(res, 409, {
      error: "version_already_published",
      dashboard_id: "com.example.errtest",
      version: "0.1.0",
      existing_content_hash: "abcdef0123456789".repeat(4),
    })
  })
  try {
    const r = await runPublish({instance, route: "x"})
    assert.equal(r.ok, false)
    const out = `${r.stdout}\n${r.stderr}`
    assert.match(out, /version_already_published/)
    assert.match(out, /already published with different bytes/)
    // CLI truncates the existing_content_hash to 12 chars before printing.
    assert.match(out, /content_hash=abcdef012345/)
    assert.match(out, /bump manifest\.version/)
  } finally {
    srv.close()
  }
})

test("unprocessable_renderer envelope tells the user to rebuild", async () => {
  const {srv, instance} = await startServer((req, res) => {
    jsonReply(res, 422, {error: "unprocessable_renderer", reason: "sha256_mismatch"})
  })
  try {
    const r = await runPublish({instance, route: "x"})
    assert.equal(r.ok, false)
    const out = `${r.stdout}\n${r.stderr}`
    assert.match(out, /unprocessable_renderer/)
    assert.match(out, /serviceradar-cli dashboard build/)
  } finally {
    srv.close()
  }
})

test("payload_too_large envelope names the part", async () => {
  const {srv, instance} = await startServer((req, res) => {
    jsonReply(res, 413, {error: "payload_too_large", part: "renderer"})
  })
  try {
    const r = await runPublish({instance, route: "x"})
    assert.equal(r.ok, false)
    const out = `${r.stdout}\n${r.stderr}`
    assert.match(out, /payload_too_large/)
    assert.match(out, /renderer part exceeds the server's size cap/)
  } finally {
    srv.close()
  }
})

test("unsupported_media_type envelope names the part", async () => {
  const {srv, instance} = await startServer((req, res) => {
    jsonReply(res, 415, {error: "unsupported_media_type", part: "manifest"})
  })
  try {
    const r = await runPublish({instance, route: "x"})
    assert.equal(r.ok, false)
    const out = `${r.stdout}\n${r.stderr}`
    assert.match(out, /unsupported_media_type/)
    assert.match(out, /manifest part has an unexpected content type/)
  } finally {
    srv.close()
  }
})

test("invalid_route envelope echoes the regex", async () => {
  const {srv, instance} = await startServer((req, res) => {
    jsonReply(res, 400, {
      error: "invalid_route",
      reason: "route_slug must match ^[a-z0-9][a-z0-9-]{1,62}$",
    })
  })
  try {
    const r = await runPublish({instance, route: "Bad/Slug.exe"})
    assert.equal(r.ok, false)
    const out = `${r.stdout}\n${r.stderr}`
    assert.match(out, /invalid_route/)
    assert.match(out, /\[a-z0-9\]/)
  } finally {
    srv.close()
  }
})

test("rate_limited envelope echoes Retry-After", async () => {
  const {srv, instance} = await startServer((req, res) => {
    jsonReply(res, 429, {error: "rate_limited", retry_after: 42}, {"retry-after": "42"})
  })
  try {
    const r = await runPublish({instance, route: "x"})
    assert.equal(r.ok, false)
    const out = `${r.stdout}\n${r.stderr}`
    assert.match(out, /rate_limited/)
    assert.match(out, /retry after 42s/)
  } finally {
    srv.close()
  }
})

test("idempotent_noop on a successful re-publish prints the noop line", async () => {
  // Exercise the success path for the "Re-published … nothing changed" hint.
  const {srv, instance} = await startServer((req, res) => {
    jsonReply(res, 200, {
      id: "pkg-uuid",
      dashboard_id: "com.example.errtest",
      version: "0.1.0",
      route_slug: "x",
      status: "staged",
      content_hash: "deadbeef".repeat(8),
      result: "idempotent_noop",
    })
  })
  try {
    const r = await runPublish({instance, route: "x", expectError: false})
    assert.equal(r.ok, true)
    assert.match(r.stdout, /Re-published/)
    assert.match(r.stdout, /already at this content_hash/)
  } finally {
    srv.close()
  }
})

test("not_found on enable surfaces the id-not-found hint", async () => {
  // The CLI flow only hits the enable endpoint when --enable is set.
  // We model that by returning a successful publish then a 404 on enable.
  let calls = 0
  const {srv, instance} = await startServer((req, res) => {
    calls += 1
    if (req.url === "/api/v1/dashboard-packages") {
      jsonReply(res, 200, {
        id: "pkg-uuid",
        dashboard_id: "com.example.errtest",
        version: "0.1.0",
        route_slug: "x",
        status: "staged",
        content_hash: "deadbeef".repeat(8),
        result: "written",
      })
    } else {
      jsonReply(res, 404, {error: "not_found", id: "pkg-uuid"})
    }
  })
  try {
    const projectDir = await buildProject()
    const args = [
      cliPath,
      "dashboard",
      "publish",
      "--instance",
      instance,
      "--token",
      "fake-jwt",
      "--route",
      "x",
      "--enable",
      "--yes",
    ]
    let captured = {ok: true, stdout: "", stderr: ""}
    try {
      const result = await execFileAsync(process.execPath, args, {cwd: projectDir})
      captured = {ok: true, ...result}
    } catch (err) {
      captured = {ok: false, code: err.code, stdout: err.stdout || "", stderr: err.stderr || ""}
    }
    assert.equal(captured.ok, false)
    const out = `${captured.stdout}\n${captured.stderr}`
    assert.match(out, /not_found/)
    assert.match(out, /pkg-uuid/)
    assert.ok(calls >= 2, "expected at least one publish hop and one enable hop")
  } finally {
    srv.close()
  }
})
