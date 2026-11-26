// Black-box and wire-conformance tests for `serviceradar pack` (`js/cli/src/pack/`).
//
// Exercises the shipped CLI entrypoint (`bin/serviceradar-cli.js` and the
// `serviceradar` bin alias) so the same test suite runs both locally under
// `npm test` and hermetically on Linux RBE under `bazel test //js/cli:pack_test`.

import {execFile} from "node:child_process"
import {createHash, createPublicKey, randomBytes, verify as cryptoVerify} from "node:crypto"
import {existsSync} from "node:fs"
import {access, cp, mkdir, mkdtemp, readFile, symlink, utimes, writeFile} from "node:fs/promises"
import {tmpdir} from "node:os"
import {join} from "node:path"
import {promisify} from "node:util"
import * as zlib from "node:zlib"
import assert from "node:assert/strict"
import test from "node:test"

const execFileAsync = promisify(execFile)
const cliRoot = new URL("..", import.meta.url).pathname
const cliBin = join(cliRoot, "bin/serviceradar-cli.js")

const VALID_ICON_SVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><defs><linearGradient id="g1"><stop offset="0%" stop-color="#2563eb"/></linearGradient></defs><rect x="4" y="4" width="40" height="40" rx="8" fill="url(#g1)"/><path d="M14 24h20" stroke="#ffffff" stroke-width="3"/></svg>`
const VALID_ICON_DATA_URI = `data:image/svg+xml;base64,${Buffer.from(VALID_ICON_SVG, "utf8").toString("base64")}`

function sha256Hex(buf) {
  return createHash("sha256").update(buf).digest("hex")
}

async function runCli(args, {cwd, env = {}, bin = cliBin} = {}) {
  const home = env.HOME || (await mkdtemp(join(tmpdir(), "sr-pack-home-")))
  try {
    const {stdout, stderr} = await execFileAsync(process.execPath, [bin, ...args], {
      cwd,
      env: {
        ...process.env,
        HOME: home,
        XDG_CONFIG_HOME: home,
        PACK_UPLOAD_SIGNING_PRIVATE_KEY: "",
        PACK_UPLOAD_SIGNING_PRIVATE_KEY_FILE: "",
        PACK_UPLOAD_SIGNING_KEY_ID: "",
        PACK_UPLOAD_SIGNING_SIGNER: "",
        PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY: "",
        PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY_FILE: "",
        PLUGIN_UPLOAD_SIGNING_KEY_ID: "",
        PLUGIN_UPLOAD_SIGNING_SIGNER: "",
        ...env,
      },
    })
    return {code: 0, stdout, stderr}
  } catch (error) {
    return {
      code: error.code ?? 1,
      stdout: error.stdout || "",
      stderr: error.stderr || "",
    }
  }
}

async function createSamplePackDir(overrides = {}) {
  const packDir = await mkdtemp(join(tmpdir(), "sr-pack-sample-"))
  await mkdir(join(packDir, "checks"), {recursive: true})
  await mkdir(join(packDir, "rules"), {recursive: true})
  await mkdir(join(packDir, "dashboards"), {recursive: true})
  await mkdir(join(packDir, "assets"), {recursive: true})

  const readmeBytes = Buffer.from(
    overrides.readme ??
      "# Synthetic Storage & NVR Health Pack\n\nMonitors storage quota utilization and recording silence.\n",
    "utf8",
  )

  const checkDoc = overrides.checkDoc ?? {
    schema_version: 1,
    slug: "storage-entitlement-utilization",
    name: "Storage Entitlement Utilization",
    state: "enabled",
    schedule: {interval_seconds: 300, timeout_seconds: 30, jitter_seconds: 15},
    target_binding: {mode: "singleton"},
    inputs: [
      {
        key: "warn_pct",
        type: "number",
        default: {"$pack_param": "utilization_warn_pct"},
      },
    ],
    credential_slots: [
      {
        slot: "archive_api",
        provider: "generic_http",
        role: "bearer_token",
        purpose: "Synthetic archive status check",
        required: false,
      },
    ],
    nodes: [
      {
        id: "posture_1",
        kind: "platform_posture",
        label: "Entitlement Utilization",
        config: {evaluator: "storage.entitlement_utilization"},
      },
      {
        id: "assert_1",
        kind: "threshold_assert",
        label: "Utilization Threshold",
        config: {
          field: "utilization_percent",
          warn: {op: ">=", value: {"$pack_param": "utilization_warn_pct"}},
        },
      },
      {
        id: "out_1",
        kind: "alert_output",
        label: "Verdict",
        config: {},
      },
    ],
    edges: [
      {id: "e1", source: "posture_1", source_handle: "signal", target: "assert_1", target_handle: "in"},
      {id: "e2", source: "assert_1", source_handle: "verdict", target: "out_1", target_handle: "in"},
    ],
  }

  const ruleDoc = overrides.ruleDoc ?? {
    name: "storage_entitlement_hard_cap",
    description: "Alerts when storage hard cap triggers",
    signal: "event",
    threshold: 1,
    window_seconds: 300,
    bucket_seconds: 60,
    cooldown_seconds: 300,
    match: {
      subject_prefix: "declarative_check.health.state_change",
      attribute_equals: {check_slug: "storage-entitlement-utilization", to_status: "down"},
    },
  }

  const pausedRuleDoc = {
    name: "camera_silence_baseline_audit",
    description: "Installed paused so operators can inspect baseline noise",
    signal: "event",
    install_state: "paused",
    threshold: 2,
    window_seconds: 600,
    bucket_seconds: 60,
    cooldown_seconds: 300,
    match: {
      subject_prefix: "declarative_check.health.state_change",
      attribute_equals: {check_slug: "camera-continuous-recording-silence", to_status: "down"},
    },
  }

  const dashboardDoc = overrides.dashboardDoc ?? {
    version: 1,
    slug: "storage-and-nvr-overview",
    title: "Storage & NVR Health Overview",
    description: "Synthetic overview dashboard",
    default_time_range: "last_24h",
    variables: {},
    metadata: {},
    panels: [
      {
        title: "Check Verdicts Over Time",
        srql_query: 'in:events stats:"count() as total by time:5m"',
        visual_type: "line",
        data_binding: {x: "bucket", y: "total"},
        layout: {x: 0, y: 0, w: 6, h: 4},
        position: 0,
      },
      {
        title: "Recent Storage Events",
        srql_query: "in:events limit:25",
        visual_type: "table",
        data_binding: {},
        layout: {x: 6, y: 0, w: 6, h: 4},
        position: 1,
      },
    ],
  }

  const assetSvgBytes = Buffer.from(overrides.assetSvg ?? VALID_ICON_SVG, "utf8")
  const checkBytes = Buffer.from(JSON.stringify(checkDoc, null, 2) + "\n", "utf8")
  const ruleBytes = Buffer.from(JSON.stringify(ruleDoc, null, 2) + "\n", "utf8")
  const pausedRuleBytes = Buffer.from(JSON.stringify(pausedRuleDoc, null, 2) + "\n", "utf8")
  const dashboardBytes = Buffer.from(JSON.stringify(dashboardDoc, null, 2) + "\n", "utf8")

  await writeFile(join(packDir, "README.md"), readmeBytes)
  await writeFile(join(packDir, "checks/entitlement-utilization.json"), checkBytes)
  await writeFile(join(packDir, "rules/storage-hard-cap-alert.json"), ruleBytes)
  await writeFile(join(packDir, "rules/camera-silence-paused.json"), pausedRuleBytes)
  await writeFile(join(packDir, "dashboards/storage-and-nvr-overview.json"), dashboardBytes)
  await writeFile(join(packDir, "assets/architecture.svg"), assetSvgBytes)

  const filesTable = overrides.filesTable ?? {
    "README.md": sha256Hex(readmeBytes),
    "assets/architecture.svg": sha256Hex(assetSvgBytes),
    "checks/entitlement-utilization.json": sha256Hex(checkBytes),
    "dashboards/storage-and-nvr-overview.json": sha256Hex(dashboardBytes),
    "rules/camera-silence-paused.json": sha256Hex(pausedRuleBytes),
    "rules/storage-hard-cap-alert.json": sha256Hex(ruleBytes),
  }

  const manifest = {
    pack_format_version: 1,
    id: "io.example.storage-nvr-sample",
    slug: "storage-nvr-sample",
    name: "Storage & NVR <Sample>",
    version: "0.1.0",
    author: "Example Ops",
    license: "Apache-2.0",
    min_serviceradar_version: "1.0.70",
    categories: ["Storage & NVR", "Infrastructure"],
    icon: VALID_ICON_DATA_URI,
    description: "Synthetic pack fixture for CLI tests.",
    config: [
      {
        key: "utilization_warn_pct",
        type: "number",
        required: false,
        default: 85,
        min: 1,
        max: 100,
        description: "Warning threshold percentage.",
      },
    ],
    credential_slots: [
      {
        slot: "archive_api",
        provider: "generic_http",
        role: "bearer_token",
        purpose: "Synthetic archive status check",
        required: false,
      },
    ],
    plugin_dependencies: [
      {
        package_id: "io.example.sample-plugin",
        version_constraint: ">= 0.1.0 and < 1.0.0",
        required: false,
      },
    ],
    resources: {
      checks: [{file: "checks/entitlement-utilization.json", slug: "storage-entitlement-utilization"}],
      rules: [
        {
          file: "rules/storage-hard-cap-alert.json",
          kind: "stateful_alert_rule",
          name: "storage_entitlement_hard_cap",
          install_state: "enabled",
        },
        {
          file: "rules/camera-silence-paused.json",
          kind: "stateful_alert_rule",
          name: "camera_silence_baseline_audit",
          install_state: "paused",
        },
      ],
      dashboards: [{file: "dashboards/storage-and-nvr-overview.json", slug: "storage-and-nvr-overview"}],
    },
    files: filesTable,
    ...(overrides.manifestPatch || {}),
  }

  await writeFile(join(packDir, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n")
  return packDir
}

function makeMinimalTarEntry(rawName, typeFlagChar, contentBuf = Buffer.alloc(0)) {
  const header = Buffer.alloc(512, 0)
  header.write(rawName, 0, Math.min(Buffer.byteLength(rawName), 100), "utf8")
  header.write("0000644\0", 100, 8, "ascii")
  header.write("0000000\0", 108, 8, "ascii")
  header.write("0000000\0", 116, 8, "ascii")
  header.write(contentBuf.length.toString(8).padStart(11, "0") + "\0", 124, 12, "ascii")
  header.write("00000000000\0", 136, 12, "ascii")
  header.fill(0x20, 148, 156)
  header[156] = typeFlagChar.charCodeAt(0)
  header.write("ustar\0", 257, 6, "ascii")
  header.write("00", 263, 2, "ascii")
  header.write("0000000\0", 329, 8, "ascii")
  header.write("0000000\0", 337, 8, "ascii")
  let sum = 0
  for (let i = 0; i < 512; i += 1) sum += header[i]
  header.write(sum.toString(8).padStart(6, "0") + "\0 ", 148, 8, "ascii")
  const padLen = contentBuf.length % 512 === 0 ? 0 : 512 - (contentBuf.length % 512)
  return Buffer.concat([header, contentBuf, Buffer.alloc(padLen, 0), Buffer.alloc(1024, 0)])
}

test("package.json declares the serviceradar bin alias and help documents pack commands", async () => {
  const pkg = JSON.parse(await readFile(join(cliRoot, "package.json"), "utf8"))
  assert.equal(pkg.bin.serviceradar, "bin/serviceradar-cli.js")

  const ver = await runCli(["--version"], {bin: join(cliRoot, pkg.bin.serviceradar)})
  assert.equal(ver.code, 0, ver.stderr)
  assert.match(ver.stdout, new RegExp(`^@carverauto/serviceradar-cli ${pkg.version.replace(/\./g, "\\.")}`, "m"))

  const help = await runCli(["pack", "help"])
  assert.equal(help.code, 0, help.stderr)
  assert.match(help.stdout, /serviceradar pack validate/)
  assert.match(help.stdout, /serviceradar pack build/)
  assert.match(help.stdout, /serviceradar pack sign/)
  assert.match(help.stdout, /serviceradar pack index/)
})

test("pack validate accepts a valid pack_format_version 1 directory", async () => {
  const packDir = await createSamplePackDir()
  const res = await runCli(["pack", "validate", packDir, "--json"])
  assert.equal(res.code, 0, res.stderr)

  const summary = JSON.parse(res.stdout)
  assert.equal(summary.valid, true)
  assert.equal(summary.id, "io.example.storage-nvr-sample")
  assert.equal(summary.version, "0.1.0")
  assert.deepEqual(summary.resource_counts, {checks: 1, rules: 2, dashboards: 1})
  assert.equal(summary.file_count, 6)
})

test("pack validate rejects unsupported pack_format_version and SHA-256 digest mismatch", async () => {
  const badVerDir = await createSamplePackDir({manifestPatch: {pack_format_version: 99}})
  const badVer = await runCli(["pack", "validate", badVerDir])
  assert.notEqual(badVer.code, 0)
  assert.match(badVer.stderr, /unsupported pack_format_version 99; expected 1 or 2/)

  const tamperedDir = await createSamplePackDir()
  await writeFile(join(tamperedDir, "README.md"), "# Modified after manifest hash\n")
  const badHash = await runCli(["pack", "validate", tamperedDir])
  assert.notEqual(badHash.code, 0)
  assert.match(badHash.stderr, /file_digest_mismatch/)
  assert.match(badHash.stderr, /README\.md/)
})

test("pack validate rejects a stateful rule match key the alert engine does not read", async () => {
  // The engine ignores unknown match keys, so such a rule would match every event.
  const rule = (match) => ({
    name: "storage_entitlement_hard_cap",
    signal: "event",
    threshold: 1,
    window_seconds: 300,
    bucket_seconds: 60,
    match,
  })

  const topLevelDir = await createSamplePackDir({ruleDoc: rule({check_slug: "storage-entitlement-utilization", status: "down"})})
  const topLevel = await runCli(["pack", "validate", topLevelDir])
  assert.notEqual(topLevel.code, 0)
  assert.match(topLevel.stderr, /\[unknown_match_key\] rules\/storage-hard-cap-alert\.json \(\$\.match\.check_slug\)/)
  assert.match(topLevel.stderr, /\[unknown_match_key\] rules\/storage-hard-cap-alert\.json \(\$\.match\.status\)/)

  const recoveryDir = await createSamplePackDir({
    ruleDoc: rule({
      subject_prefix: "declarative_check.health.state_change",
      recovery: {to_status: "healthy"},
    }),
  })
  const recovery = await runCli(["pack", "validate", recoveryDir])
  assert.notEqual(recovery.code, 0)
  assert.match(recovery.stderr, /\(\$\.match\.recovery\.to_status\)/)
})

test("pack validate enforces SecretFreeValidator parity against secret keys, tokens, and live UUIDs", async () => {
  // 1. Secret-bearing key inside a check node config
  const secretKeyDir = await createSamplePackDir({
    checkDoc: {
      schema_version: 1,
      slug: "storage-entitlement-utilization",
      nodes: [
        {
          id: "http_1",
          kind: "http_request",
          config: {url: "https://api.example.test/health", api_key: "placeholder"},
        },
      ],
      edges: [],
    },
  })
  const r1 = await runCli(["pack", "validate", secretKeyDir])
  assert.notEqual(r1.code, 0)
  assert.match(r1.stderr, /forbidden_secret_key/)
  assert.match(r1.stderr, /checks\/entitlement-utilization\.json/)
  assert.match(r1.stderr, /api_key/)

  // 2. Live credential_secret_id or database row UUID leaked into export
  const uuidDir = await createSamplePackDir({
    ruleDoc: {
      id: "00000000-0000-4000-8000-000000000010",
      name: "storage_entitlement_hard_cap",
      credential_secret_id: "00000000-0000-4000-8000-000000000011",
      threshold: 1,
    },
  })
  const r2 = await runCli(["pack", "validate", uuidDir])
  assert.notEqual(r2.code, 0)
  assert.match(r2.stderr, /forbidden_instance_uuid/)
  assert.match(r2.stderr, /credential_secret_id/)

  // 3. Token prefix literal constructed dynamically at runtime (keeps source file 0-leak clean)
  const syntheticPat = "ghp_" + "x".repeat(24)
  const tokenDir = await createSamplePackDir({
    readme: `# Pack Docs\n\nNever embed ${syntheticPat} in documentation.\n`,
  })
  const r3 = await runCli(["pack", "validate", tokenDir])
  assert.notEqual(r3.code, 0)
  assert.match(r3.stderr, /secret_token_literal/)
  assert.match(r3.stderr, /README\.md/)

  // 4. Multiline/newline literal Authorization header in JSON fails closed (1:1 Elixir parity)
  const jsonMultilineAuthDir = await createSamplePackDir({
    checkDoc: {
      schema_version: 1,
      slug: "storage-entitlement-utilization",
      nodes: [
        {
          id: "http_1",
          kind: "http_request",
          config: {
            url: "https://api.example.test/health",
            headers_note: "Authorization: Bearer\nreal_token_123456",
          },
        },
      ],
      edges: [],
    },
  })
  const r4 = await runCli(["pack", "validate", jsonMultilineAuthDir])
  assert.notEqual(r4.code, 0)
  assert.match(r4.stderr, /literal_auth_credential/)
  assert.match(r4.stderr, /checks\/entitlement-utilization\.json/)
})

test("pack validate rejects unsafe SVGs, unlisted files, symlinks, cyclic check DAGs, and overlapping dashboard panels", async () => {
  // Unsafe <script> in manifest icon
  const badSvg = `<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>`
  const svgDir = await createSamplePackDir({
    manifestPatch: {
      icon: `data:image/svg+xml;base64,${Buffer.from(badSvg, "utf8").toString("base64")}`,
    },
  })
  const svgRes = await runCli(["pack", "validate", svgDir])
  assert.notEqual(svgRes.code, 0)
  assert.match(svgRes.stderr, /forbidden_svg_element/)

  // Unlisted file in checks/
  const unlistedDir = await createSamplePackDir()
  await writeFile(join(unlistedDir, "checks/rogue.json"), "{}\n")
  const unlistedRes = await runCli(["pack", "validate", unlistedDir])
  assert.notEqual(unlistedRes.code, 0)
  assert.match(unlistedRes.stderr, /unlisted_resource_file|unlisted_file/)
  assert.match(unlistedRes.stderr, /checks\/rogue\.json/)

  // Symlink inside pack directory
  const symlinkDir = await createSamplePackDir()
  await symlink(join(symlinkDir, "README.md"), join(symlinkDir, "assets/linked.md"))
  const symRes = await runCli(["pack", "validate", symlinkDir])
  assert.notEqual(symRes.code, 0)
  assert.match(symRes.stderr, /unsafe symlink/)

  // Cyclic check DAG
  const cycleDir = await createSamplePackDir({
    checkDoc: {
      schema_version: 1,
      slug: "storage-entitlement-utilization",
      nodes: [
        {id: "a", kind: "threshold_assert", config: {}},
        {id: "b", kind: "alert_output", config: {}},
      ],
      edges: [
        {id: "e1", source: "a", target: "b"},
        {id: "e2", source: "b", target: "a"},
      ],
    },
  })
  const cycleRes = await runCli(["pack", "validate", cycleDir])
  assert.notEqual(cycleRes.code, 0)
  assert.match(cycleRes.stderr, /cyclic_check_dag/)

  // Overlapping 12-column dashboard panels
  const overlapDir = await createSamplePackDir({
    dashboardDoc: {
      version: 1,
      slug: "storage-and-nvr-overview",
      title: "Overlapping Dashboard",
      panels: [
        {
          title: "Panel A",
          srql_query: "in:events limit:10",
          visual_type: "table",
          layout: {x: 0, y: 0, w: 8, h: 4},
        },
        {
          title: "Panel B",
          srql_query: "in:events limit:10",
          visual_type: "table",
          layout: {x: 6, y: 0, w: 6, h: 4},
        },
      ],
    },
  })
  const overlapRes = await runCli(["pack", "validate", overlapDir])
  assert.notEqual(overlapRes.code, 0)
  assert.match(overlapRes.stderr, /overlapping_dashboard_panels/)
})

test("pack build produces byte-for-byte deterministic tar.zst .srpack archives across builds and mtimes", async () => {
  const dirA = await createSamplePackDir({filesTable: {}})
  const dirB = await createSamplePackDir({filesTable: {}})

  // Perturb filesystem mtimes on dirB to prove tar + zstd framing strips host mtimes
  const oldDate = new Date("2021-03-04T05:06:07Z")
  const recentDate = new Date("2025-09-10T11:12:13Z")
  await utimes(join(dirA, "README.md"), oldDate, oldDate)
  await utimes(join(dirB, "README.md"), recentDate, recentDate)

  const outDir = await mkdtemp(join(tmpdir(), "sr-pack-out-"))
  const outA = join(outDir, "a.srpack")
  const outB = join(outDir, "b.srpack")

  const buildA = await runCli(["pack", "build", dirA, "-o", outA, "--write-manifest", "--json"])
  assert.equal(buildA.code, 0, buildA.stderr)

  const buildB = await runCli(["pack", "build", dirB, "-o", outB, "--refresh-files", "--json"])
  assert.equal(buildB.code, 0, buildB.stderr)

  const bytesA = await readFile(outA)
  const bytesB = await readFile(outB)
  assert.equal(sha256Hex(bytesA), sha256Hex(bytesB))
  assert.deepEqual(bytesA, bytesB)

  // Verify zstd frame magic (0x28 0xB5 0x2F 0xFD) when running on Node >= 22.15
  if (typeof zlib.zstdDecompressSync === "function") {
    assert.equal(bytesA[0], 0x28)
    assert.equal(bytesA[1], 0xb5)
    assert.equal(bytesA[2], 0x2f)
    assert.equal(bytesA[3], 0xfd)

    // Inspect raw POSIX USTAR header determinism inside the zstd frame
    const tarBytes = zlib.zstdDecompressSync(bytesA)
    assert.equal(tarBytes.subarray(257, 263).toString("ascii"), "ustar\0")
    assert.equal(tarBytes.subarray(100, 107).toString("ascii"), "0000644")
    assert.equal(tarBytes.subarray(108, 115).toString("ascii"), "0000000") // uid = 0
    assert.equal(tarBytes.subarray(116, 123).toString("ascii"), "0000000") // gid = 0
    assert.equal(tarBytes.subarray(136, 147).toString("ascii"), "00000000000") // mtime = 0
    assert.equal(tarBytes.subarray(265, 297).indexOf(0), 0) // uname = ""
    assert.equal(tarBytes.subarray(297, 329).indexOf(0), 0) // gname = ""
    // First sorted entry is README.md ('R' = 0x52 < 'a' = 0x61)
    assert.equal(tarBytes.subarray(0, 9).toString("utf8"), "README.md")
  }

  // Validate both the refreshed directory and the built .srpack archive directly
  const valDir = await runCli(["pack", "validate", dirA])
  assert.equal(valDir.code, 0, valDir.stderr)

  const valArchive = await runCli(["pack", "validate", outA])
  assert.equal(valArchive.code, 0, valArchive.stderr)
})

test("pack validate rejects .srpack archives containing path traversal or symlinks", async () => {
  const workDir = await mkdtemp(join(tmpdir(), "sr-pack-badtar-"))

  const traversalTar = makeMinimalTarEntry("../evil.json", "0", Buffer.from("{}"))
  const traversalPath = join(workDir, "traversal.srpack")
  await writeFile(
    traversalPath,
    typeof zlib.zstdCompressSync === "function"
      ? zlib.zstdCompressSync(traversalTar)
      : zlib.gzipSync(traversalTar),
  )
  const r1 = await runCli(["pack", "validate", traversalPath])
  assert.notEqual(r1.code, 0)
  assert.match(r1.stderr, /path traversal/)

  const symlinkTar = makeMinimalTarEntry("README.md", "2")
  const symlinkPath = join(workDir, "symlink.srpack")
  await writeFile(
    symlinkPath,
    typeof zlib.zstdCompressSync === "function"
      ? zlib.zstdCompressSync(symlinkTar)
      : zlib.gzipSync(symlinkTar),
  )
  const r2 = await runCli(["pack", "validate", symlinkPath])
  assert.notEqual(r2.code, 0)
  assert.match(r2.stderr, /unsupported or unsafe tar entry type/)
})

test("pack keygen, sign, verify, and cross-language Ed25519 UploadSignature conformance vector", async () => {
  // 1. Verify cross-language conformance vector shared with Elixir `UploadSignature`
  //    and Go `upload_signature_tool_test.go` (synthetic low-entropy seed 0x11 * 32).
  const conformanceDir = await mkdtemp(join(tmpdir(), "sr-pack-conformance-"))
  const readmeContent = Buffer.from("# Conformance Pack\n", "utf8")
  const readmeSha = sha256Hex(readmeContent)
  await writeFile(join(conformanceDir, "README.md"), readmeContent)

  const conformanceManifest = {
    pack_format_version: 1,
    id: "io.example.conformance-pack",
    slug: "conformance-pack",
    name: "Conformance <Pack>",
    version: "0.1.0",
    categories: ["Storage & NVR"],
    config: [],
    credential_slots: [],
    plugin_dependencies: [],
    resources: {checks: [], dashboards: [], rules: []},
    files: {"README.md": readmeSha},
  }
  await writeFile(join(conformanceDir, "manifest.json"), JSON.stringify(conformanceManifest, null, 2) + "\n")

  const srpackPath = join(conformanceDir, "conformance-pack-0.1.0.srpack")
  const buildRes = await runCli(["pack", "build", conformanceDir, "-o", srpackPath])
  assert.equal(buildRes.code, 0, buildRes.stderr)

  const srpackBytes = await readFile(srpackPath)
  const srpackHash = sha256Hex(srpackBytes)

  const seedHex = "11".repeat(32)
  const expectedPubKeyB64 = "0EqyMnQrtKs6E2i9RhXk5tAiSrcaAWuvhSCjMsl3hzc="

  const signRes = await runCli([
    "pack",
    "sign",
    srpackPath,
    "--key",
    seedHex,
    "--key-id",
    "conformance-key-1",
    "--signer",
    "serviceradar-ci",
  ])
  assert.equal(signRes.code, 0, signRes.stderr)

  const sigDoc = JSON.parse(await readFile(`${srpackPath}.sig`, "utf8"))
  assert.equal(sigDoc.algorithm, "ed25519")
  assert.equal(sigDoc.key_id, "conformance-key-1")
  assert.equal(sigDoc.signer, "serviceradar-ci")
  assert.equal(sigDoc.content_hash, srpackHash)

  // Verify the exact canonical JSON payload signed by `pack sign` (note literal `&`, `<`, `>`)
  const expectedCanonicalPayload =
    `{"content_hash":"${srpackHash}","manifest":{"categories":["Storage & NVR"],"config":[],"credential_slots":[],"files":{"README.md":"${readmeSha}"},"id":"io.example.conformance-pack","name":"Conformance <Pack>","pack_format_version":1,"plugin_dependencies":[],"resources":{"checks":[],"dashboards":[],"rules":[]},"slug":"conformance-pack","version":"0.1.0"}}`

  const spkiPrefix = Buffer.from("302a300506032b6570032100", "hex")
  const pubKeyObj = createPublicKey({
    key: Buffer.concat([spkiPrefix, Buffer.from(expectedPubKeyB64, "base64")]),
    format: "der",
    type: "spki",
  })
  assert.equal(
    cryptoVerify(
      null,
      Buffer.from(expectedCanonicalPayload, "utf8"),
      pubKeyObj,
      Buffer.from(sigDoc.signature, "base64"),
    ),
    true,
    "Ed25519 signature must verify over exact canonical JSON payload with literal &, <, >",
  )

  // Verify via CLI `pack verify`
  const verOk = await runCli(["pack", "verify", srpackPath, "--public-key", expectedPubKeyB64])
  assert.equal(verOk.code, 0, verOk.stderr)

  // 2. End-to-end `pack keygen` -> `pack sign` -> `pack verify` + isolation failure on wrong key
  const keyDir = await mkdtemp(join(tmpdir(), "sr-pack-keys-"))
  const keygenA = await runCli(["pack", "keygen", "--out-dir", keyDir, "--key-id", "repo-a", "--json"])
  assert.equal(keygenA.code, 0, keygenA.stderr)
  const keyInfoA = JSON.parse(keygenA.stdout)

  const keygenB = await runCli(["pack", "keygen", "--out-dir", keyDir, "--key-id", "repo-b", "--json"])
  assert.equal(keygenB.code, 0, keygenB.stderr)
  const keyInfoB = JSON.parse(keygenB.stdout)

  const sigByA = join(conformanceDir, "repo-a.sig")
  const signA = await runCli([
    "pack",
    "sign",
    srpackPath,
    "--key",
    keyInfoA.private_key_file,
    "--key-id",
    "repo-a",
    "-o",
    sigByA,
  ])
  assert.equal(signA.code, 0, signA.stderr)

  const verifyWithA = await runCli([
    "pack",
    "verify",
    srpackPath,
    "--signature",
    sigByA,
    "--public-key",
    keyInfoA.public_key_file,
  ])
  assert.equal(verifyWithA.code, 0, verifyWithA.stderr)

  const verifyWithB = await runCli([
    "pack",
    "verify",
    srpackPath,
    "--signature",
    sigByA,
    "--public-key",
    keyInfoB.public_key_file,
  ])
  assert.notEqual(verifyWithB.code, 0)
  assert.match(verifyWithB.stderr, /verification failed/)
})

test("pack index builds deterministic serviceradar-pack-index.json for GitHub releases and base URLs", async () => {
  const packDir = await createSamplePackDir()
  const distDir = await mkdtemp(join(tmpdir(), "sr-pack-dist-"))
  const srpackFile = join(distDir, "storage-nvr-sample-0.1.0.srpack")

  const built = await runCli(["pack", "build", packDir, "-o", srpackFile])
  assert.equal(built.code, 0, built.stderr)

  const keyDir = await mkdtemp(join(tmpdir(), "sr-pack-idx-keys-"))
  const kg = JSON.parse((await runCli(["pack", "keygen", "--out-dir", keyDir, "--key-id", "official-1", "--json"])).stdout)

  const signed = await runCli([
    "pack",
    "sign",
    srpackFile,
    "--key",
    kg.private_key_file,
    "--key-id",
    "official-1",
  ])
  assert.equal(signed.code, 0, signed.stderr)

  const indexOut = join(distDir, "serviceradar-pack-index.json")
  const idxRes = await runCli([
    "pack",
    "index",
    distDir,
    "-o",
    indexOut,
    "--repo",
    "carverauto/serviceradar-apps",
    "--release-tag",
    "v0.1.0",
    "--require-signatures",
    "--public-key",
    kg.public_key_file,
  ])
  assert.equal(idxRes.code, 0, idxRes.stderr)

  const indexBytes1 = await readFile(indexOut)
  const indexDoc = JSON.parse(indexBytes1.toString("utf8"))
  assert.equal(indexDoc.format_version, 1)
  assert.equal(indexDoc.packs.length, 1)

  const entry = indexDoc.packs[0]
  const expectedSha = sha256Hex(await readFile(srpackFile))
  assert.equal(entry.id, "io.example.storage-nvr-sample")
  assert.equal(entry.slug, "storage-nvr-sample")
  assert.equal(entry.version, "0.1.0")
  assert.equal(entry.signed, true)
  assert.equal(entry.signing_key_id, "official-1")
  assert.equal(entry.bundle_digest, expectedSha)
  assert.equal(entry.sha256, expectedSha)
  assert.equal(
    entry.bundle_url,
    "https://github.com/carverauto/serviceradar-apps/releases/download/v0.1.0/storage-nvr-sample-0.1.0.srpack",
  )
  assert.equal(
    entry.signature_url,
    "https://github.com/carverauto/serviceradar-apps/releases/download/v0.1.0/storage-nvr-sample-0.1.0.srpack.sig",
  )
  assert.equal(entry.upload_signature_url, entry.signature_url)
  assert.deepEqual(entry.resource_counts, {checks: 1, rules: 2, dashboards: 1})
  assert.equal(entry.manifest.id, "io.example.storage-nvr-sample")

  // Re-running produces identical index bytes
  const indexOut2 = join(distDir, "serviceradar-pack-index-2.json")
  const idxRes2 = await runCli([
    "pack",
    "index",
    srpackFile,
    "-o",
    indexOut2,
    "--base-url",
    "https://github.com/carverauto/serviceradar-apps/releases/download/v0.1.0",
  ])
  assert.equal(idxRes2.code, 0, idxRes2.stderr)
  const indexBytes2 = await readFile(indexOut2)
  assert.deepEqual(indexBytes1, indexBytes2)
})

async function createSampleV2PackDir({withDashboardPackage = true, overrides = {}} = {}) {
  const packDir = await mkdtemp(join(tmpdir(), "sr-pack-v2-"))
  await mkdir(join(packDir, "vantage_pipelines"), {recursive: true})
  await mkdir(join(packDir, "signal_schemas"), {recursive: true})
  if (withDashboardPackage) {
    await mkdir(join(packDir, "dashboard_packages/alpr-console"), {recursive: true})
  }

  const readmeBytes = Buffer.from(
    "# Vantage ALPR Synthetic Pack\n\nMonitors Gate West 01 (SR-0100, TEST-742).\n",
    "utf8",
  )

  const pipelineDoc = overrides.pipelineDoc ?? {
    pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
    version: "1.0.0",
    name: "ALPR Vehicle Plate Reader",
    description: "Synthetic ALPR pipeline for Gate West 01.",
    enabled: true,
    source_mode: "recorded_block",
    trigger_kind: "on_stage1_detection",
    camera_selector: "tag:gate-west-01",
    object_classes: ["vehicle"],
    min_confidence: 0.55,
    roi_polygons: [
      [
        [0.05, 0.2],
        [0.95, 0.2],
        [0.95, 0.95],
        [0.05, 0.95],
      ],
    ],
    input_mode: "detection_crop",
    crop_policy: {
      padding_ratio: 0.15,
      min_bbox_width_px: 96,
      max_dimension: 640,
      max_bytes: 98304,
    },
    max_jobs_per_minute: 60,
    max_frames_per_track: 3,
    runner: "camera_vlm",
    capability: "vantage.alpr.v1",
    fallback_runner: "camera_vlm",
    vlm_config: {
      prompt: "Read the synthetic plate (SR-0100, TEST-742) and return strict JSON.",
      model_profile: "vantage-vlm-fast",
      max_tokens: 256,
      temperature: 0.0,
    },
    signal_schema_id: "alpr_plate_read",
    signal_schema_version: "1.0.0",
    display_contract_id: "alpr_plate_read",
    emit_ocsf_events: true,
    live_observation_retention_days: 30,
  }

  const schemaDoc = overrides.schemaDoc ?? {
    $schema: "https://json-schema.org/draft/2020-12/schema",
    id: "alpr_plate_read",
    version: "1.0.0",
    type: "object",
    required: ["plate_text"],
    additionalProperties: false,
    properties: {
      plate_text: {type: "string", pattern: "^[A-Z0-9-]{2,12}$"},
      region: {type: "string", maxLength: 32},
      confidence: {type: "number", minimum: 0.0, maximum: 1.0},
    },
  }

  const displayDoc = overrides.displayDoc ?? {
    id: "alpr_plate_read",
    version: "1.0.0",
    title: "ALPR Plate Read",
    badge: {label: "Plate", color: "#0EA5E9", icon: "hero-identification"},
    scrubber_marker: {category: "license_plate", color: "#0EA5E9", label_field: "plate_text"},
    overlay: {label_template: "{{plate_text}}", stroke_color: "#0EA5E9", show_confidence: true},
    crop_preview: {enabled: true, max_bytes: 32768, alt_template: "Crop for {{plate_text}}"},
  }

  const pipelineBytes = Buffer.from(JSON.stringify(pipelineDoc, null, 2) + "\n", "utf8")
  const schemaBytes = Buffer.from(JSON.stringify(schemaDoc, null, 2) + "\n", "utf8")
  const displayBytes = Buffer.from(JSON.stringify(displayDoc, null, 2) + "\n", "utf8")

  await writeFile(join(packDir, "README.md"), readmeBytes)
  await writeFile(join(packDir, "vantage_pipelines/alpr-vehicle-plate.json"), pipelineBytes)
  await writeFile(join(packDir, "signal_schemas/alpr_plate_read.schema.json"), schemaBytes)
  await writeFile(join(packDir, "signal_schemas/alpr_plate_read.display.json"), displayBytes)

  const filesTable = {
    "README.md": sha256Hex(readmeBytes),
    "signal_schemas/alpr_plate_read.display.json": sha256Hex(displayBytes),
    "signal_schemas/alpr_plate_read.schema.json": sha256Hex(schemaBytes),
    "vantage_pipelines/alpr-vehicle-plate.json": sha256Hex(pipelineBytes),
  }

  const resources = {
    checks: [],
    rules: [],
    dashboards: [],
    vantage_pipelines: [
      {
        id: "io.serviceradar.vantage-alpr.vehicle-plate",
        slug: "alpr-vehicle-plate",
        file: "vantage_pipelines/alpr-vehicle-plate.json",
      },
    ],
    signal_schemas: [
      {
        id: "alpr_plate_read",
        version: "1.0.0",
        file: "signal_schemas/alpr_plate_read.schema.json",
        display_file: "signal_schemas/alpr_plate_read.display.json",
      },
    ],
  }

  if (withDashboardPackage) {
    const rendererBytes =
      overrides.rendererBytes ??
      Buffer.from(
        'export const MODULE_VERSION = "dashboard-browser-module-v1";\nexport function mountDashboard() { return { samplePlates: ["SR-0100", "TEST-742"] }; }\n',
        "utf8",
      )
    const dashManifestDoc = overrides.dashManifestDoc ?? {
      schema_version: 1,
      id: "io.serviceradar.alpr-console",
      name: "ALPR Synthetic Console",
      version: "1.0.0",
      description: "Synthetic ALPR dashboard module for Gate West 01.",
      vendor: "ServiceRadar",
      renderer: {
        kind: "browser_module",
        interface_version: "dashboard-browser-module-v1",
        artifact: "renderer.js",
        sha256: sha256Hex(rendererBytes),
        trust: "trusted",
      },
      data_frames: [
        {
          id: "recent_plate_reads",
          query: "in:camera_observations category:license_plate sort:timeline_ts_us:desc limit:100",
          encoding: "json_rows",
          required: true,
        },
      ],
      capabilities: ["camera.stream.view", "events.subscribe", "srql.execute"],
    }
    const dashManifestBytes = Buffer.from(JSON.stringify(dashManifestDoc, null, 2) + "\n", "utf8")
    await writeFile(join(packDir, "dashboard_packages/alpr-console/renderer.js"), rendererBytes)
    await writeFile(join(packDir, "dashboard_packages/alpr-console/manifest.json"), dashManifestBytes)
    filesTable["dashboard_packages/alpr-console/manifest.json"] = sha256Hex(dashManifestBytes)
    filesTable["dashboard_packages/alpr-console/renderer.js"] = sha256Hex(rendererBytes)
    resources.dashboard_packages = [
      {
        slug: "alpr-console",
        dir: "dashboard_packages/alpr-console",
        manifest_file: "dashboard_packages/alpr-console/manifest.json",
        renderer_file: "dashboard_packages/alpr-console/renderer.js",
      },
    ]
  }

  const manifest = {
    pack_format_version: 2,
    id: "io.serviceradar.vantage-alpr",
    slug: "vantage-alpr",
    name: "Vantage ALPR",
    version: "1.0.0",
    license: "Apache-2.0",
    author: "ServiceRadar",
    categories: ["camera", "vantage-ml"],
    worker_dependencies: [
      {
        capability: "vantage.alpr.v1",
        min_protocol_version: "vantage.worker.v1",
        optional: true,
        fallback_runner: "camera_vlm",
      },
    ],
    dashboard_package_dependencies: [
      {
        dashboard_id: "io.serviceradar.alpr-console",
        version_range: ">=1.0.0",
      },
    ],
    resources,
    files: filesTable,
    ...(overrides.manifestPatch || {}),
  }

  await writeFile(join(packDir, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n")
  return packDir
}

test("pack v2 validate, build, sign, verify, and index round-trip with 6-key resource_counts", async () => {
  const packDir = await createSampleV2PackDir()
  const valRes = await runCli(["pack", "validate", packDir, "--json"])
  assert.equal(valRes.code, 0, valRes.stderr)
  const summary = JSON.parse(valRes.stdout)
  assert.equal(summary.valid, true)
  assert.deepEqual(summary.resource_counts, {
    checks: 0,
    rules: 0,
    dashboards: 0,
    vantage_pipelines: 1,
    signal_schemas: 1,
    dashboard_packages: 1,
  })

  const distDir = await mkdtemp(join(tmpdir(), "sr-pack-v2-dist-"))
  const srpackPath = join(distDir, "vantage-alpr-1.0.0.srpack")
  const buildRes = await runCli(["pack", "build", packDir, "-o", srpackPath, "--json"])
  assert.equal(buildRes.code, 0, buildRes.stderr)
  const builtJson = JSON.parse(buildRes.stdout)
  assert.equal(builtJson.resource_counts.vantage_pipelines, 1)
  assert.equal(builtJson.resource_counts.signal_schemas, 1)
  assert.equal(builtJson.resource_counts.dashboard_packages, 1)

  const valArc = await runCli(["pack", "validate", srpackPath, "--json"])
  assert.equal(valArc.code, 0, valArc.stderr)

  const keyDir = await mkdtemp(join(tmpdir(), "sr-pack-v2-keys-"))
  const kg = JSON.parse((await runCli(["pack", "keygen", "--out-dir", keyDir, "--key-id", "v2-key-1", "--json"])).stdout)
  const signRes = await runCli(["pack", "sign", srpackPath, "--key", kg.private_key_file, "--key-id", "v2-key-1", "--json"])
  assert.equal(signRes.code, 0, signRes.stderr)
  const verRes = await runCli(["pack", "verify", srpackPath, "--public-key", kg.public_key_file, "--json"])
  assert.equal(verRes.code, 0, verRes.stderr)
  assert.equal(JSON.parse(verRes.stdout).verified, true)

  const idxOut = join(distDir, "serviceradar-pack-index.json")
  const idxRes = await runCli(["pack", "index", distDir, "-o", idxOut, "--base-url", "https://packages.example.test", "--require-signatures", "--public-key", kg.public_key_file, "--json"])
  assert.equal(idxRes.code, 0, idxRes.stderr)
  const idx = JSON.parse(await readFile(idxOut, "utf8"))
  assert.equal(idx.format_version, 1)
  assert.equal(idx.packs[0].resource_counts.dashboard_packages, 1)
})

test("pack validate rejects v2 fields in v1 packs and circular signal_schema $ref", async () => {
  for (const [scope, field] of [
    ["root", "worker_dependencies"],
    ["root", "dashboard_package_dependencies"],
    ["resources", "vantage_pipelines"],
    ["resources", "signal_schemas"],
    ["resources", "dashboard_packages"],
  ]) {
    const patch =
      scope === "root"
        ? {[field]: []}
        : {
            resources: {
              checks: [],
              rules: [],
              dashboards: [],
              [field]: [],
            },
          }
    const v1BadDir = await createSamplePackDir({manifestPatch: patch})
    const res = await runCli(["pack", "validate", v1BadDir])
    assert.notEqual(res.code, 0)
    assert.match(res.stderr, /forbidden in pack_format_version=1/)
  }

  const cycleSchemaDir = await createSampleV2PackDir({
    withDashboardPackage: false,
    overrides: {
      schemaDoc: {
        $schema: "https://json-schema.org/draft/2020-12/schema",
        id: "alpr_plate_read",
        version: "1.0.0",
        type: "object",
        $defs: {
          nodeA: {$ref: "#/$defs/nodeB"},
          nodeB: {$ref: "#/$defs/nodeA"},
        },
        properties: {
          plate_text: {$ref: "#/$defs/nodeA"},
        },
      },
    },
  })
  const cycleRes = await runCli(["pack", "validate", cycleSchemaDir])
  assert.notEqual(cycleRes.code, 0)
  assert.match(cycleRes.stderr, /circular_json_schema_ref/)
})

test("pack v2 enforces 8 MiB MAX_RENDERER_BYTES, triple SHA-256 parity, and JS-aware SecretFreeValidator", async () => {
  // 1. Exact 8 MiB renderer passes; 8 MiB + 1 byte fails with MAX_RENDERER_BYTES and emits no .srpack
  const exactDir = await createSampleV2PackDir({
    overrides: {rendererBytes: Buffer.alloc(8 * 1024 * 1024, "a")},
  })
  const exactVal = await runCli(["pack", "validate", exactDir])
  assert.equal(exactVal.code, 0, exactVal.stderr)

  const overDir = await createSampleV2PackDir({
    overrides: {rendererBytes: Buffer.alloc(8 * 1024 * 1024 + 1, "a")},
  })
  const overOut = join(overDir, "should-not-exist.srpack")
  const overBuild = await runCli(["pack", "build", overDir, "-o", overOut])
  assert.notEqual(overBuild.code, 0)
  assert.match(overBuild.stderr, /MAX_RENDERER_BYTES/)
  await assert.rejects(() => access(overOut))

  // 2. Tampering renderer.js even with --refresh-files fails due to dashboard manifest SHA-256 parity
  const tamperDir = await createSampleV2PackDir()
  await writeFile(
    join(tamperDir, "dashboard_packages/alpr-console/renderer.js"),
    "export function mountDashboard() { return { tampered: true }; }\n",
  )
  const tamperOut = join(tamperDir, "tamper.srpack")
  const tamperBuild = await runCli(["pack", "build", tamperDir, "-o", tamperOut, "--refresh-files"])
  assert.notEqual(tamperBuild.code, 0)
  assert.match(tamperBuild.stderr, /!= actual renderer SHA-256/)
  await assert.rejects(() => access(tamperOut))

  // 3. Benign minified JS identifiers, header-prefix concatenation/interpolation, and comments pass while literal tokens, auth credentials (single/multiline/aws4), and PEM blocks fail
  const benignDir = await createSampleV2PackDir({
    overrides: {
      rendererBytes: Buffer.from(
        [
          "// Authorization: Bearer",
          "const x = 1;",
          'const quoteRe = /"/g; const ratio = 1 / 2;',
          "export function render(token,secretKey,password,authHeader,tok,creds){",
          '  return{token,secretKey,password,authHeader,quoteRe,ratio,raw:"Authorization: Bearer " + token,basic:\'Authorization: Basic \' + creds,tpl:`Authorization: Bearer ${tok}`};',
          "}",
        ].join("\n") + "\n",
        "utf8",
      ),
    },
  })
  const benignRes = await runCli(["pack", "validate", benignDir])
  assert.equal(benignRes.code, 0, benignRes.stderr)

  for (const [leakedLiteral, expectedCode] of [
    ["ghp_" + "SyntheticToken0123456789", /secret_token_literal/],
    ["ghr_" + "SyntheticRefresh0123456789", /secret_token_literal/],
    ["github_pat_" + "11SYNTHETIC_0123456789abcdef", /secret_token_literal/],
    ["-----BEGIN RSA PRIVATE KEY-----\nMIIE_SYNTHETIC_KEY_DATA", /pem_private_key/],
    ["Authorization: Bearer real_token_123456", /literal_auth_credential/],
    ["Authorization: Bearer synthetic-bearer-token-value-12345", /literal_auth_credential/],
    ["Authorization: Bearer\nreal_token_123456", /literal_auth_credential/],
    ["Authorization: AWS4-HMAC-SHA256 Credential=my_secret_cred_value", /literal_auth_credential/],
  ]) {
    const leakDir = await createSampleV2PackDir({
      overrides: {
        rendererBytes: Buffer.from(`export const leaked = ${JSON.stringify(leakedLiteral)};\n`, "utf8"),
      },
    })
    const leakRes = await runCli(["pack", "validate", leakDir])
    assert.notEqual(leakRes.code, 0, `expected secret leak rejection for ${leakedLiteral.slice(0, 12)}`)
    assert.match(leakRes.stderr, expectedCode)
  }

  for (const [label, jsSnippet] of [
    ["template literal newline", "export const h = `Authorization: Bearer\nreal_token_123456`;\n"],
    ["template literal space+newline", "export const h = `Authorization: Bearer \nreal_token_123456`;\n"],
    ["template literal crlf", "export const h = `Authorization: Bearer\r\nreal_token_123456`;\n"],
    ["escaped newline after regex quote", 'if (globalThis.x) /"/.test("a");\nexport const h = "Authorization: Bearer\\nreal_token_123456";\n'],
  ]) {
    const jsLeakDir = await createSampleV2PackDir({
      overrides: {
        rendererBytes: Buffer.from(jsSnippet, "utf8"),
      },
    })
    const jsLeakRes = await runCli(["pack", "validate", jsLeakDir])
    assert.notEqual(jsLeakRes.code, 0, `expected JS secret leak rejection for ${label}`)
    assert.match(jsLeakRes.stderr, /literal_auth_credential/)
  }
})

test("pack v2 rejects UUID in string-form dashboard_package_dependencies and accepts vantage_pipelines pipeline_id", async () => {
  const validStringDepDir = await createSampleV2PackDir({
    withDashboardPackage: false,
    overrides: {
      manifestPatch: {
        dashboard_package_dependencies: ["io.serviceradar.alpr-console@1.0.0"],
      },
    },
  })
  const validStringRes = await runCli(["pack", "validate", validStringDepDir])
  assert.equal(validStringRes.code, 0, validStringRes.stderr)

  const uuidStringDepDir = await createSampleV2PackDir({
    withDashboardPackage: false,
    overrides: {
      manifestPatch: {
        dashboard_package_dependencies: ["11111111-2222-4333-8444-555555555555@1.0.0"],
      },
    },
  })
  const uuidStringRes = await runCli(["pack", "validate", uuidStringDepDir])
  assert.notEqual(uuidStringRes.code, 0)
  assert.match(uuidStringRes.stderr, /forbidden_instance_uuid/)

  const baseManifestDir = await createSampleV2PackDir({withDashboardPackage: false})
  const baseManifest = JSON.parse(await readFile(join(baseManifestDir, "manifest.json"), "utf8"))
  baseManifest.resources.vantage_pipelines = [
    {
      pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
      file: "vantage_pipelines/alpr-vehicle-plate.json",
    },
  ]
  await writeFile(join(baseManifestDir, "manifest.json"), JSON.stringify(baseManifest, null, 2) + "\n")
  const pipelineIdRes = await runCli(["pack", "validate", baseManifestDir])
  assert.equal(pipelineIdRes.code, 0, pipelineIdRes.stderr)

  baseManifest.resources.vantage_pipelines = [
    {
      pipeline_id: "io.serviceradar.vantage-alpr.other-pipeline",
      file: "vantage_pipelines/alpr-vehicle-plate.json",
    },
  ]
  await writeFile(join(baseManifestDir, "manifest.json"), JSON.stringify(baseManifest, null, 2) + "\n")
  const pipelineMismatchRes = await runCli(["pack", "validate", baseManifestDir])
  assert.notEqual(pipelineMismatchRes.code, 0)
  assert.match(pipelineMismatchRes.stderr, /pipeline_id_mismatch/)
})

test("pack v2 archive cap is 25 MiB without dashboard_packages and 32 MiB with dashboard_packages", async () => {
  // 26 MiB of incompressible random bytes inside assets/blob.bin
  const blob = randomBytes(26 * 1024 * 1024)

  const noDashDir = await createSampleV2PackDir({withDashboardPackage: false})
  await mkdir(join(noDashDir, "assets"), {recursive: true})
  await writeFile(join(noDashDir, "assets/blob.bin"), blob)
  const noDashOut = join(noDashDir, "no-dash.srpack")
  const noDashBuild = await runCli(["pack", "build", noDashDir, "-o", noDashOut, "--refresh-files"])
  assert.notEqual(noDashBuild.code, 0)
  assert.match(noDashBuild.stderr, /exceeds 26214400 bytes/)
  await assert.rejects(() => access(noDashOut))

  const withDashDir = await createSampleV2PackDir({withDashboardPackage: true})
  await mkdir(join(withDashDir, "assets"), {recursive: true})
  await writeFile(join(withDashDir, "assets/blob.bin"), blob)
  const withDashOut = join(withDashDir, "with-dash.srpack")
  const withDashBuild = await runCli(["pack", "build", withDashDir, "-o", withDashOut, "--refresh-files"])
  assert.equal(withDashBuild.code, 0, withDashBuild.stderr)
  const withDashVal = await runCli(["pack", "validate", withDashOut])
  assert.equal(withDashVal.code, 0, withDashVal.stderr)
})

function resolveVantageAlprPackDir() {
  const rel = "elixir/serviceradar_core/priv/solution_packs/vantage-alpr"
  const candidates = [
    join(cliRoot, "../../", rel),
    process.env.TEST_SRCDIR && join(process.env.TEST_SRCDIR, process.env.TEST_WORKSPACE || "_main", rel),
    process.env.RUNFILES_DIR &&
      join(process.env.RUNFILES_DIR, process.env.TEST_WORKSPACE || "_main", rel),
  ].filter(Boolean)

  const found = candidates.find((candidate) => existsSync(join(candidate, "manifest.json")))
  assert.ok(found, `unable to locate shipped vantage-alpr pack in: ${candidates.join(", ")}`)
  return found
}

test("shipped io.serviceradar.vantage-alpr pack passes pack validate, deterministic pack build, 3-way SHA-256 parity, and tamper rejection", async () => {
  const packDir = resolveVantageAlprPackDir()

  const valRes = await runCli(["pack", "validate", "--dir", packDir, "--json"])
  assert.equal(valRes.code, 0, valRes.stderr)
  const valJson = JSON.parse(valRes.stdout)
  assert.equal(valJson.valid, true)
  assert.equal(valJson.id, "io.serviceradar.vantage-alpr")
  assert.equal(valJson.slug, "vantage-alpr")
  assert.deepEqual(valJson.resource_counts, {
    checks: 1,
    rules: 1,
    dashboards: 1,
    vantage_pipelines: 1,
    signal_schemas: 1,
    dashboard_packages: 1,
  })
  assert.equal(valJson.file_count, 10)

  const manifest = JSON.parse(await readFile(join(packDir, "manifest.json"), "utf8"))
  const dashManifest = JSON.parse(
    await readFile(join(packDir, "dashboard_packages/alpr-console/manifest.json"), "utf8"),
  )
  const rendererBytes = await readFile(join(packDir, "dashboard_packages/alpr-console/renderer.js"))
  const actualRendererSha = sha256Hex(rendererBytes)
  assert.ok(rendererBytes.length > 0 && rendererBytes.length <= 8 * 1024 * 1024)
  assert.equal(dashManifest.renderer.sha256, actualRendererSha)
  assert.equal(manifest.files["dashboard_packages/alpr-console/renderer.js"], actualRendererSha)

  const outDir = await mkdtemp(join(tmpdir(), "sr-vantage-alpr-build-"))
  const srpackA = join(outDir, "alpr-a.srpack")
  const srpackB = join(outDir, "alpr-b.srpack")

  const buildA = await runCli(["pack", "build", packDir, "-o", srpackA, "--json"])
  assert.equal(buildA.code, 0, buildA.stderr)
  const buildB = await runCli(["pack", "build", packDir, "-o", srpackB, "--json"])
  assert.equal(buildB.code, 0, buildB.stderr)
  assert.equal(sha256Hex(await readFile(srpackA)), sha256Hex(await readFile(srpackB)))

  const arcVal = await runCli(["pack", "validate", srpackA, "--json"])
  assert.equal(arcVal.code, 0, arcVal.stderr)
  const arcValJson = JSON.parse(arcVal.stdout)
  assert.equal(arcValJson.valid, true)
  assert.equal(arcValJson.source_kind, "archive")

  // Tamper renderer.js and confirm fail-closed validation/build
  const tamperedDir = join(outDir, "tampered")
  await cp(packDir, tamperedDir, {recursive: true})
  await writeFile(
    join(tamperedDir, "dashboard_packages/alpr-console/renderer.js"),
    "export function mountDashboard(){}\n",
  )
  const tamperedVal = await runCli(["pack", "validate", "--dir", tamperedDir])
  assert.notEqual(tamperedVal.code, 0)
  assert.match(tamperedVal.stderr, /sha256|mismatch/i)
})
