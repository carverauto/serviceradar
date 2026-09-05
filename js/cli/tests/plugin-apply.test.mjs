import {execFile} from "node:child_process"
import {createServer} from "node:http"
import {mkdtemp, writeFile} from "node:fs/promises"
import {tmpdir} from "node:os"
import {join} from "node:path"
import {promisify} from "node:util"
import test from "node:test"
import assert from "node:assert/strict"

const execFileAsync = promisify(execFile)
const cliPath = new URL("../bin/serviceradar-cli.js", import.meta.url).pathname

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

test("plugin apply is idempotent and never sends secret values from the file", async () => {
  const writes = []
  const projectDir = await mkdtemp(join(tmpdir(), "sr-plugin-apply-"))
  const playbook = join(projectDir, "demo.yaml")
  await writeFile(
    playbook,
    `
secrets:
  - name: demo-netbox
    provider: netbox
    auth_method: api_token
    values_from:
      api_token: SERVICERADAR_DEMO_NETBOX_TOKEN
rules:
  - name: demo-netbox-inventory
    provider: netbox
    auth_method: api_token
    purpose: inventory_sync
    secret: demo-netbox
    scope_type: agent
    scope_value: agent-site01-01
    target_query: "in:devices sort:uid:asc limit:1"
    tls_policy: verify
assignments:
  - plugin_id: netbox-inventory
    agent_uid: agent-site01-01
    enabled: true
`,
  )

  await withServer(async (req, res) => {
    const url = new URL(req.url, "http://127.0.0.1")
    if (req.method === "GET" && url.pathname === "/api/admin/network-credential-secrets") {
      res.setHeader("content-type", "application/json")
      res.end(JSON.stringify([{id: "secret-1", name: "demo-netbox", provider: "netbox"}]))
      return
    }
    if (req.method === "GET" && url.pathname === "/api/admin/network-credential-rules") {
      res.setHeader("content-type", "application/json")
      res.end(JSON.stringify([]))
      return
    }
    if (req.method === "GET" && url.pathname === "/api/admin/plugin-packages") {
      res.setHeader("content-type", "application/json")
      res.end(JSON.stringify([{id: "pkg-1", plugin_id: "netbox-inventory", status: "approved"}]))
      return
    }
    if (req.method === "GET" && url.pathname === "/api/admin/plugin-assignments") {
      res.setHeader("content-type", "application/json")
      res.end(JSON.stringify([]))
      return
    }
    if (req.method === "POST" || req.method === "PATCH") {
      const body = JSON.parse((await readBody(req)).toString() || "{}")
      writes.push({method: req.method, path: url.pathname, body})
      res.statusCode = req.method === "POST" ? 201 : 200
      res.setHeader("content-type", "application/json")
      res.end(JSON.stringify({id: "created-1", ...body}))
      return
    }
    res.statusCode = 404
    res.end("{}")
  }, async (instance) => {
    const {code, stdout, stderr} = await runCli(
      ["plugin", "apply", "--instance", instance, "--file", playbook, "--token", "test-token"],
      {env: {...process.env, SERVICERADAR_DEMO_NETBOX_TOKEN: "synthetic-token"}},
    )
    assert.equal(code, 0, stderr)
    assert.match(stdout, /secret demo-netbox: keep secret-1/)
    assert.match(stdout, /rule demo-netbox-inventory: created/)
    assert.match(stdout, /assignment netbox-inventory@agent-site01-01: created/)
    const ruleWrite = writes.find((item) => item.path === "/api/admin/network-credential-rules")
    assert.ok(ruleWrite)
    assert.equal(ruleWrite.body.secret_id, "secret-1")
    assert.equal(ruleWrite.body.tls_policy, "verify")
    assert.doesNotMatch(JSON.stringify(writes), /synthetic-token/)
  })
})

test("plugin apply fails when a required secret env var is missing and no secret exists", async () => {
  const playbookDir = await mkdtemp(join(tmpdir(), "sr-plugin-apply-missing-"))
  const playbook = join(playbookDir, "demo.yaml")
  await writeFile(
    playbook,
    `
secrets:
  - name: demo-netbox
    provider: netbox
    auth_method: api_token
    values_from:
      api_token: SERVICERADAR_DEMO_NETBOX_TOKEN
`,
  )

  await withServer(async (req, res) => {
    res.setHeader("content-type", "application/json")
    res.end("[]")
  }, async (instance) => {
    const env = {...process.env}
    delete env.SERVICERADAR_DEMO_NETBOX_TOKEN
    const {code, stderr} = await runCli(
      ["plugin", "apply", "--instance", instance, "--file", playbook, "--token", "test-token"],
      {env},
    )
    assert.notEqual(code, 0)
    assert.match(stderr, /SERVICERADAR_DEMO_NETBOX_TOKEN/)
  })
})

test("help documents plugin apply", async () => {
  const {stdout} = await runCli(["help"])
  assert.match(stdout, /plugin apply/)
  assert.match(stdout, /plugins\.manage/)
})
