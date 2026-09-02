// Black-box tests for the `serviceradar-cli plugin` group.
//
// Same shape as publish-errors.test.mjs: a canned http server stands in for an
// instance and the CLI runs as a subprocess, so the tests exercise the shipped
// bin rather than importing from dist/.

import {execFile} from "node:child_process"
import {createServer} from "node:http"
import {mkdir, mkdtemp, writeFile} from "node:fs/promises"
import {tmpdir} from "node:os"
import {join} from "node:path"
import {promisify} from "node:util"
import test from "node:test"
import assert from "node:assert/strict"

const execFileAsync = promisify(execFile)
const cliPath = new URL("../bin/serviceradar-cli.js", import.meta.url).pathname

const WASM_HEADER = Buffer.from([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00])

const VALID_MANIFEST = `id: example-check
name: Example Check
version: 0.1.0
entrypoint: run_check
outputs: serviceradar.plugin_result.v1
capabilities:
  - get_config
  - log
  - submit_result
resources:
  requested_memory_mb: 64
  requested_cpu_ms: 2000
`

async function buildProject({manifest = VALID_MANIFEST, wasm = WASM_HEADER} = {}) {
  const projectDir = await mkdtemp(join(tmpdir(), "sr-plugin-cli-"))
  await writeFile(join(projectDir, "plugin.yaml"), manifest)
  if (wasm !== null) {
    await writeFile(join(projectDir, "plugin.wasm"), wasm)
  }
  return projectDir
}

async function withServer(handler, run) {
  const server = createServer(handler)
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve))
  const {port} = server.address()
  try {
    return await run(`http://127.0.0.1:${port}`)
  } finally {
    await new Promise((resolve) => server.close(resolve))
  }
}

async function runCli(args, options = {}) {
  try {
    const {stdout, stderr} = await execFileAsync(process.execPath, [cliPath, ...args], options)
    return {code: 0, stdout, stderr}
  } catch (error) {
    return {code: error.code ?? 1, stdout: error.stdout || "", stderr: error.stderr || ""}
  }
}

function readBody(req) {
  return new Promise((resolve) => {
    const chunks = []
    req.on("data", (chunk) => chunks.push(chunk))
    req.on("end", () => resolve(Buffer.concat(chunks)))
  })
}

test("validate accepts a manifest matching the server contract", async () => {
  const projectDir = await buildProject()
  const {code, stdout} = await runCli(["plugin", "validate"], {cwd: projectDir})

  assert.equal(code, 0)
  assert.match(stdout, /plugin\.yaml is valid/)
  assert.match(stdout, /example-check@0\.1\.0/)
  assert.match(stdout, /requests: get_config, log, submit_result/)
})

test("validate rejects a manifest missing capabilities and resources", async () => {
  // Both are required by ServiceRadar.Plugins.Manifest; the CLI must not be
  // laxer than the server or "validate passed" becomes meaningless.
  const projectDir = await buildProject({
    manifest: "id: example-check\nname: Example\nversion: 0.1.0\nentrypoint: run_check\noutputs: serviceradar.plugin_result.v1\n",
  })
  const {code, stderr} = await runCli(["plugin", "validate"], {cwd: projectDir})

  assert.notEqual(code, 0)
  assert.match(stderr, /capabilities is required/)
  assert.match(stderr, /resources is required/)
})

test("validate does not require runtime, which the server allows to be absent", async () => {
  const {code} = await runCli(["plugin", "validate"], {cwd: await buildProject()})
  assert.equal(code, 0)
})

test("validate rejects a malformed plugin id", async () => {
  const projectDir = await buildProject({manifest: VALID_MANIFEST.replace("example-check", "Example_Check")})
  const {code, stderr} = await runCli(["plugin", "validate"], {cwd: projectDir})

  assert.notEqual(code, 0)
  assert.match(stderr, /must be lowercase alphanumeric/)
})

test("validate makes no network calls", async () => {
  let hits = 0
  await withServer(
    (_req, res) => {
      hits += 1
      res.writeHead(200, {"content-type": "application/json"})
      res.end("{}")
    },
    async (instance) => {
      const projectDir = await buildProject()
      const {code} = await runCli(["plugin", "validate", "--instance", instance], {cwd: projectDir})
      assert.equal(code, 0)
    },
  )

  assert.equal(hits, 0)
})

test("publish stages the package and uploads the bundle with the storage token", async () => {
  const projectDir = await buildProject()
  const seen = []

  const result = await withServer(
    async (req, res) => {
      const body = await readBody(req)
      seen.push({method: req.method, url: req.url, headers: req.headers, body})

      if (req.method === "POST" && req.url === "/api/admin/plugin-packages") {
        res.writeHead(201, {"content-type": "application/json"})
        res.end(JSON.stringify({id: "pkg-123", status: "staged"}))
        return
      }
      if (req.method === "POST" && req.url === "/api/admin/plugin-packages/pkg-123/upload-url") {
        res.writeHead(200, {"content-type": "application/json"})
        res.end(JSON.stringify({upload_url: "/api/plugin-packages/pkg-123/blob", upload_token: "storage-tok"}))
        return
      }
      if (req.method === "PUT" && req.url === "/api/plugin-packages/pkg-123/blob") {
        res.writeHead(200, {"content-type": "application/json"})
        res.end(JSON.stringify({ok: true}))
        return
      }
      res.writeHead(404, {"content-type": "application/json"})
      res.end(JSON.stringify({error: "not_found"}))
    },
    (instance) =>
      runCli(["plugin", "publish", "--instance", instance, "--token", "user-tok", "--yes"], {cwd: projectDir}),
  )

  assert.equal(result.code, 0, result.stderr)
  assert.match(result.stdout, /Staged example-check@0\.1\.0/)
  assert.match(result.stdout, /package id: pkg-123/)

  const [create, uploadUrl, upload] = seen
  assert.equal(create.headers.authorization, "Bearer user-tok")
  assert.equal(JSON.parse(create.body).plugin_id, "example-check")
  assert.equal(JSON.parse(create.body).source_type, "upload")
  assert.equal(uploadUrl.headers.authorization, "Bearer user-tok")

  // The blob route reads x-serviceradar-plugin-token and ignores a bearer;
  // sending the user token here would both fail and over-share the credential.
  assert.equal(upload.headers["x-serviceradar-plugin-token"], "storage-tok")
  assert.equal(upload.headers.authorization, undefined)
  assert.deepEqual(upload.body, WASM_HEADER)
})

test("publish fails before any request when the wasm is missing", async () => {
  let hits = 0
  const projectDir = await buildProject({wasm: null})

  const result = await withServer(
    (_req, res) => {
      hits += 1
      res.writeHead(200, {"content-type": "application/json"})
      res.end("{}")
    },
    (instance) => runCli(["plugin", "publish", "--instance", instance, "--token", "t", "--yes"], {cwd: projectDir}),
  )

  assert.notEqual(result.code, 0)
  assert.match(result.stderr, /plugin\.wasm does not exist/)
  assert.equal(hits, 0)
})

test("publish rejects a file that is not a wasm binary", async () => {
  const projectDir = await buildProject({wasm: Buffer.from("#!/bin/sh\necho nope\n")})
  const result = await runCli(["plugin", "publish", "--instance", "https://example.test", "--token", "t", "--yes"], {
    cwd: projectDir,
  })

  assert.notEqual(result.code, 0)
  assert.match(result.stderr, /not a WebAssembly binary/)
})

test("publish requires a credential", async () => {
  const projectDir = await buildProject()
  const result = await runCli(["plugin", "publish", "--instance", "https://example.test", "--yes"], {
    cwd: projectDir,
    env: {...process.env, SERVICERADAR_TOKEN: "", HOME: projectDir},
  })

  assert.notEqual(result.code, 0)
  assert.match(result.stderr, /no token resolved/)
  assert.match(result.stderr, /auth login/)
})

test("publish explains an insufficient_scope refusal", async () => {
  const projectDir = await buildProject()

  const result = await withServer(
    (_req, res) => {
      res.writeHead(403, {"content-type": "application/json"})
      res.end(JSON.stringify({error: "insufficient_scope", granted: ["dashboard.publish"]}))
    },
    (instance) =>
      runCli(["plugin", "publish", "--instance", instance, "--token", "t", "--yes"], {cwd: projectDir}),
  )

  assert.notEqual(result.code, 0)
  assert.match(result.stderr, /plugin\.publish/)
  assert.match(result.stderr, /it holds: dashboard\.publish/)
})

test("publish reports the package id when the upload fails after staging", async () => {
  const projectDir = await buildProject()

  const result = await withServer(
    async (req, res) => {
      await readBody(req)
      if (req.method === "POST" && req.url === "/api/admin/plugin-packages") {
        res.writeHead(201, {"content-type": "application/json"})
        res.end(JSON.stringify({id: "pkg-orphan", status: "staged"}))
        return
      }
      res.writeHead(500, {"content-type": "application/json"})
      res.end(JSON.stringify({error: "boom"}))
    },
    (instance) =>
      runCli(["plugin", "publish", "--instance", instance, "--token", "t", "--yes"], {cwd: projectDir}),
  )

  assert.notEqual(result.code, 0)
  // Without the id the developer cannot tell whether anything landed.
  assert.match(result.stderr, /pkg-orphan was created but has no bundle/)
})

test("status reports approval state and approved capabilities", async () => {
  const result = await withServer(
    (req, res) => {
      assert.equal(req.url, "/api/admin/plugin-packages/pkg-9")
      res.writeHead(200, {"content-type": "application/json"})
      res.end(
        JSON.stringify({
          id: "pkg-9",
          plugin_id: "example-check",
          version: "0.1.0",
          status: "approved",
          source_type: "upload",
          approved_capabilities: ["get_config", "log"],
        }),
      )
    },
    (instance) => runCli(["plugin", "status", "--instance", instance, "--id", "pkg-9", "--token", "t"]),
  )

  assert.equal(result.code, 0, result.stderr)
  assert.match(result.stdout, /status:  approved/)
  assert.match(result.stdout, /approved capabilities: get_config, log/)
})

test("status surfaces a staged package as awaiting approval", async () => {
  const result = await withServer(
    (_req, res) => {
      res.writeHead(200, {"content-type": "application/json"})
      res.end(JSON.stringify({id: "pkg-1", plugin_id: "x", version: "1", status: "staged", source_type: "upload"}))
    },
    (instance) => runCli(["plugin", "status", "--instance", instance, "--id", "pkg-1", "--token", "t"]),
  )

  assert.equal(result.code, 0, result.stderr)
  assert.match(result.stdout, /awaiting administrator approval/)
})

test("init scaffolds a go project whose manifest validates", async () => {
  const workDir = await mkdtemp(join(tmpdir(), "sr-plugin-init-"))
  const init = await runCli(["plugin", "init", "my-probe", "--template", "go"], {cwd: workDir})

  assert.equal(init.code, 0, init.stderr)

  const projectDir = join(workDir, "my-probe")
  const validate = await runCli(["plugin", "validate"], {cwd: projectDir})

  assert.equal(validate.code, 0, validate.stderr)
  assert.match(validate.stdout, /my-probe@0\.1\.0/)
})

test("init scaffolds a rust project whose manifest validates", async () => {
  const workDir = await mkdtemp(join(tmpdir(), "sr-plugin-init-rs-"))
  const init = await runCli(["plugin", "init", "my-rust-probe", "--template", "rust"], {cwd: workDir})

  assert.equal(init.code, 0, init.stderr)

  const validate = await runCli(["plugin", "validate"], {cwd: join(workDir, "my-rust-probe")})

  assert.equal(validate.code, 0, validate.stderr)
  assert.match(validate.stdout, /my-rust-probe@0\.1\.0/)
})

test("init refuses an unknown template", async () => {
  const workDir = await mkdtemp(join(tmpdir(), "sr-plugin-init-bad-"))
  const {code, stderr} = await runCli(["plugin", "init", "x", "--template", "cobol"], {cwd: workDir})

  assert.notEqual(code, 0)
  assert.match(stderr, /unknown template: cobol/)
})

test("init refuses to overwrite a non-empty directory without --force", async () => {
  const workDir = await mkdtemp(join(tmpdir(), "sr-plugin-init-busy-"))
  await mkdir(join(workDir, "taken"), {recursive: true})
  await writeFile(join(workDir, "taken", "keep.txt"), "keep")

  const {code, stderr} = await runCli(["plugin", "init", "taken"], {cwd: workDir})

  assert.notEqual(code, 0)
  assert.match(stderr, /already exists and is not empty/)
})

test("an unknown plugin subcommand is reported", async () => {
  const {code, stderr} = await runCli(["plugin", "frobnicate"])

  assert.notEqual(code, 0)
  assert.match(stderr, /unknown subcommand: plugin frobnicate/)
})
