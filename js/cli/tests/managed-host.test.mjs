import assert from "node:assert/strict"
import {mkdtemp, readFile, readdir, rm, stat} from "node:fs/promises"
import {tmpdir} from "node:os"
import {join} from "node:path"
import {createServer} from "node:http"
import test from "node:test"
import {parse as parseToml} from "smol-toml"
import {atomicOwnedFile, decodePolicyPublicKey, managedConfigurationFiles, mergeManagedConfiguration, selectLeafAdvertiseURL, waitForManagedActivation} from "../managed-host.mjs"

test("managed configuration uses fixed destinations and binds offline access to a local leaf identity", () => {
  const component = {
    component_id: "component-a", service: "bmp-collector", partition_id: "default", blocked: false,
    configuration: {"bmp-collector.json": JSON.stringify({nats_url: "tls://localhost:4222"})},
    local_leaf_binding: {version: 1, endpoint: "tls://localhost:4222", server_spiffe_id: "spiffe://serviceradar.local/nats_leaf_server/default/leaf-a-server"},
  }
  const files = managedConfigurationFiles(component, true)
  const binding = files.find((file) => file.path.endsWith("/local-leaf.json"))
  assert.equal(binding.path, "/etc/serviceradar/managed-components/component-a/local-leaf.json")
  assert.deepEqual(JSON.parse(binding.content), component.local_leaf_binding)
  assert.equal(binding.mode, 0o644)
  assert.ok(files.some((file) => file.path === "/etc/systemd/system/serviceradar-bmp-collector.service.d/managed-config.conf"))
  assert.throws(() => managedConfigurationFiles(component, false), /only valid for collectors/)
  assert.throws(() => managedConfigurationFiles({...component, component_id: "../other"}, true), /invalid managed/)
  assert.throws(() => managedConfigurationFiles({...component, configuration: {...component.configuration, "../../other": "bad"}}, true), /unsupported managed/)
  assert.throws(() => managedConfigurationFiles({...component, local_leaf_binding: {...component.local_leaf_binding, server_spiffe_id: "spiffe://serviceradar.local/nats_leaf_server/other/leaf-a-server"}}, true), /does not identify/)
})

test("adoption retains enabled log pipelines and input settings while replacing NATS credentials and policy", () => {
  const launcher = parseToml(mergeManagedConfiguration("log-collector.toml", '[otel]\nenabled=true\nconfig_file="/old/otel.toml"\n[health]\nlisten_addr="127.0.0.1:50100"', '[flowgger]\nenabled=true\nconfig_file="/etc/serviceradar/flowgger.toml"\n[otel]\nenabled=false\nconfig_file="/etc/serviceradar/otel.toml"'))
  assert.equal(launcher.otel.enabled, true)
  assert.equal(launcher.flowgger.enabled, true)
  assert.equal(launcher.otel.config_file, "/etc/serviceradar/otel.toml")
  assert.equal(launcher.health.listen_addr, "127.0.0.1:50100")
  const previous = '[input]\nlisten="127.0.0.1:1514"\n[output]\nformat="json"\nnats_url="tls://old.example:4222"\nnats_creds_file="/old.creds"\n[logging]\nlevel="debug"'
  const next = '[input]\nlisten="0.0.0.0:514"\n[output]\ntype="nats"\nformat="gelf"\nnats_url="tls://localhost:4222"\nnats_cert_policy_file="/etc/serviceradar/managed-components/policy.json"'
  const merged = parseToml(mergeManagedConfiguration("flowgger.toml", previous, next))
  assert.equal(merged.input.listen, "127.0.0.1:1514")
  assert.equal(merged.logging.level, "debug")
  assert.equal(merged.output.format, "json")
  assert.equal(merged.output.nats_url, "tls://localhost:4222")
  assert.equal(merged.output.nats_creds_file, undefined)
  assert.equal(merged.output.nats_cert_policy_file, "/etc/serviceradar/managed-components/policy.json")
  assert.throws(() => mergeManagedConfiguration("otel.toml", "[broken", "[nats]"))
})

test("flow adoption preserves bundled listeners with canonical subjects and replaces TLS credentials", () => {
  const previous = {listeners: [{protocol: "sflow", listen_addr: "127.0.0.1:16343", subject: "old.subject"}], batch_size: 42, nats_creds_file: "/old.creds", security: {mode: "none"}}
  const next = {listeners: [{protocol: "netflow", listen_addr: "0.0.0.0:2055", subject: "flows.raw.netflow"}], nats_url: "tls://localhost:4222", security: {mode: "mtls", cert_policy_file: "/policy.json"}}
  const merged = JSON.parse(mergeManagedConfiguration("flow-collector.json", JSON.stringify(previous), JSON.stringify(next)))
  assert.equal(merged.batch_size, 42)
  assert.deepEqual(merged.listeners.find((listener) => listener.protocol === "sflow"), {protocol: "sflow", listen_addr: "127.0.0.1:16343", subject: "flows.raw.sflow"})
  assert.ok(merged.listeners.some((listener) => listener.protocol === "netflow"))
  assert.equal(merged.nats_creds_file, undefined)
  assert.deepEqual(merged.security, next.security)
})

test("atomic publication survives restrictive umask, refuses initial overwrite and cleans failed temporaries", async () => {
  const dir = await mkdtemp(join(tmpdir(), "managed-host-"))
  const path = join(dir, "policy.pub")
  const previousMask = process.umask(0o077)
  try {
    await atomicOwnedFile(path, "first", 0o644, process.getuid(), process.getgid(), false)
    assert.equal((await stat(path)).mode & 0o777, 0o644)
    await assert.rejects(atomicOwnedFile(path, "second", 0o600, process.getuid(), process.getgid(), false), {code: "EEXIST"})
    assert.equal(await readFile(path, "utf8"), "first")
    assert.deepEqual(await readdir(dir), ["policy.pub"])
    await atomicOwnedFile(path, "rotated", 0o640, process.getuid(), process.getgid())
    assert.equal(await readFile(path, "utf8"), "rotated")
    assert.equal((await stat(path)).mode & 0o777, 0o640)
  } finally {
    process.umask(previousMask)
    await rm(dir, {recursive: true, force: true})
  }
})

test("deployment bootstrap accepts only canonical Ed25519 public keys", () => {
  const key = Buffer.alloc(32, 19).toString("base64")
  assert.equal(decodePolicyPublicKey(key + "\n"), key)
  for (const invalid of ["", "not-base64", Buffer.alloc(31).toString("base64"), key + "!"]) assert.throws(() => decodePolicyPublicKey(invalid), /Ed25519/)
})

test("leaf address selection prefers operator configuration and uses only unambiguous host addresses", () => {
  const addresses = ["127.0.0.1", "::1", "169.254.1.2", "fe80::1", "192.0.2.24"]
  assert.equal(selectLeafAdvertiseURL(undefined, undefined, "edge", addresses, []), "tls://192.0.2.24:4222")
  assert.equal(selectLeafAdvertiseURL(undefined, "tls://localhost:4222", "leaf.example", addresses, ["192.0.2.24"]), "tls://leaf.example:4222")
  assert.equal(selectLeafAdvertiseURL("tls://leaf.example:4322", "tls://old.example:4222", "edge", [], []), "tls://leaf.example:4322")
  assert.equal(selectLeafAdvertiseURL(undefined, "nats://leaf.example:4222", "edge", [], []), "tls://leaf.example:4222")
  assert.equal(selectLeafAdvertiseURL(undefined, undefined, "edge", ["2001:db8::24"], []), "tls://[2001:db8::24]:4222")
  assert.throws(() => selectLeafAdvertiseURL(undefined, undefined, "edge", ["127.0.0.1"], []), /--advertise-url/)
  assert.throws(() => selectLeafAdvertiseURL(undefined, undefined, "leaf.example", ["192.0.2.24", "198.51.100.24"], ["203.0.113.1"]), /--advertise-url/)
  for (const value of ["https://leaf.example:4222", "tls://user:pass@leaf.example:4222", "tls://leaf.example:4222/path", "tls://leaf.example"]) {
    assert.throws(() => selectLeafAdvertiseURL(value, undefined, "edge", [], []), /--advertise-url/)
  }
})

test("activation polling waits for both receipts from the requested operation and rejects failures or stale results", async () => {
  let receipts
  let reads
  const server = createServer((req, res) => {
    assert.equal(req.url, "/api/admin/managed-components/component-a")
    assert.equal(req.headers.authorization, "Bearer synthetic-token")
    reads++
    const lifecycle = receipts.length > 1 ? receipts.shift() : receipts[0]
    res.writeHead(200, {"content-type": "application/json"})
    res.end(JSON.stringify({data: {lifecycle}}))
  })
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve))
  const session = {instance: `http://127.0.0.1:${server.address().port}`, token: "synthetic-token"}
  try {
    reads = 0
    receipts = [{operation_id: "operation-a", installed: true, activated: false}, {operation_id: "operation-a", installed: true, activated: true, enforcement_status: "unconfirmed"}]
    await waitForManagedActivation(session, "component-a", "operation-a", 1, 0.001)
    assert.equal(reads, 2)
    for (const [receipt, reason] of [
      [{operation_id: "old-operation", installed: true, activated: true}, /operation changed/],
      [{operation_id: "operation-a", status: "failed", error: "service activation failed"}, /service activation failed/],
      [{operation_id: "operation-a", installed: true, activated: false}, /timed out/],
    ]) {
      receipts = [receipt]
      await assert.rejects(waitForManagedActivation(session, "component-a", "operation-a", 0.01, 0.001), reason)
    }
  } finally { await new Promise((resolve) => server.close(resolve)) }
})
