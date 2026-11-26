// Black-box tests for `serviceradar vantage init|validate|dev` (`js/cli/src/vantage/`).
//
// Exercises the shipped CLI entrypoint (`bin/serviceradar-cli.js`) so the suite
// runs identically under both `npm test` and Bazel RBE (`//js/cli:vantage_test`).

import {execFile} from "node:child_process"
import {existsSync} from "node:fs"
import {access, mkdir, mkdtemp, readFile, stat, writeFile} from "node:fs/promises"
import {tmpdir} from "node:os"
import {join} from "node:path"
import {promisify} from "node:util"
import assert from "node:assert/strict"
import test from "node:test"

const execFileAsync = promisify(execFile)
const cliRoot = new URL("..", import.meta.url).pathname
const cliBin = join(cliRoot, "bin/serviceradar-cli.js")

async function runCli(args, {cwd, env = {}} = {}) {
  const home = env.HOME || (await mkdtemp(join(tmpdir(), "sr-vantage-home-")))
  try {
    const {stdout, stderr} = await execFileAsync(process.execPath, [binPath(), ...args], {
      cwd,
      env: {
        ...process.env,
        HOME: home,
        XDG_CONFIG_HOME: home,
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

function binPath() {
  return cliBin
}

test("vantage help documents init, validate, and dev subcommands", async () => {
  const res = await runCli(["vantage", "help"])
  assert.equal(res.code, 0, res.stderr)
  assert.match(res.stdout, /serviceradar-cli vantage init/)
  assert.match(res.stdout, /serviceradar-cli vantage validate/)
  assert.match(res.stdout, /serviceradar-cli vantage dev/)
})

test("vantage init scaffolds vlm --with-dashboard, python-worker, and rust-worker and passes validate + pack build", async () => {
  const workDir = await mkdtemp(join(tmpdir(), "sr-vantage-init-"))

  // 1. vlm --with-dashboard
  const vlmInit = await runCli(
    ["vantage", "init", "demo-alpr", "--template", "vlm", "--with-dashboard", "--json"],
    {cwd: workDir},
  )
  assert.equal(vlmInit.code, 0, vlmInit.stderr)
  const vlmJson = JSON.parse(vlmInit.stdout)
  assert.equal(vlmJson.created, true)
  assert.equal(vlmJson.template, "vlm")
  assert.equal(vlmJson.with_dashboard, true)

  const vlmDir = join(workDir, "demo-alpr")
  await access(join(vlmDir, "manifest.json"))
  await access(join(vlmDir, "vantage_pipelines/demo-alpr-pipeline.json"))
  await access(join(vlmDir, "signal_schemas/demo_alpr_signal.schema.json"))
  await access(join(vlmDir, "signal_schemas/demo_alpr_signal.display.json"))
  await access(join(vlmDir, "dashboard_packages/demo-alpr-console/manifest.json"))
  await access(join(vlmDir, "dashboard_packages/demo-alpr-console/renderer.js"))

  const vlmVal = await runCli(["vantage", "validate", vlmDir, "--json"])
  assert.equal(vlmVal.code, 0, vlmVal.stderr)
  const vlmValJson = JSON.parse(vlmVal.stdout)
  assert.equal(vlmValJson.valid, true)
  assert.equal(vlmValJson.pack_format_version, 2)
  assert.equal(vlmValJson.resource_counts.dashboard_packages, 1)

  const vlmSrpack = join(workDir, "demo-alpr.srpack")
  const vlmBuild = await runCli(["pack", "build", vlmDir, "-o", vlmSrpack, "--json"])
  assert.equal(vlmBuild.code, 0, vlmBuild.stderr)
  const vlmArcVal = await runCli(["pack", "validate", vlmSrpack, "--json"])
  assert.equal(vlmArcVal.code, 0, vlmArcVal.stderr)

  // 2. python-worker
  const pyInit = await runCli(
    ["vantage", "init", "demo-py-alpr", "--template", "python-worker", "--json"],
    {cwd: workDir},
  )
  assert.equal(pyInit.code, 0, pyInit.stderr)
  const pyDir = join(workDir, "demo-py-alpr")
  await access(join(pyDir, "manifest.json"))
  await access(join(pyDir, "vantage_pipelines/demo-py-alpr-pipeline.json"))
  await access(join(pyDir, "signal_schemas/demo_py_alpr_signal.schema.json"))
  await access(join(pyDir, "worker/main.py"))
  await access(join(pyDir, "worker/__init__.py"))
  await access(join(pyDir, "worker/pyproject.toml"))

  const pyVal = await runCli(["vantage", "validate", pyDir, "--json"])
  assert.equal(pyVal.code, 0, pyVal.stderr)
  assert.equal(JSON.parse(pyVal.stdout).worker_kind, "python-worker")

  const pySrpack = join(workDir, "demo-py-alpr.srpack")
  const pyBuild = await runCli(["pack", "build", pyDir, "-o", pySrpack, "--json"])
  assert.equal(pyBuild.code, 0, pyBuild.stderr)
  assert.equal((await runCli(["pack", "validate", pySrpack])).code, 0)

  // 3. rust-worker
  const rsInit = await runCli(
    ["vantage", "init", "demo-rs-alpr", "--template", "rust-worker", "--json"],
    {cwd: workDir},
  )
  assert.equal(rsInit.code, 0, rsInit.stderr)
  const rsDir = join(workDir, "demo-rs-alpr")
  await access(join(rsDir, "manifest.json"))
  await access(join(rsDir, "vantage_pipelines/demo-rs-alpr-pipeline.json"))
  await access(join(rsDir, "signal_schemas/demo_rs_alpr_signal.schema.json"))
  await access(join(rsDir, "Cargo.toml"))
  await access(join(rsDir, "src/main.rs"))

  const rsVal = await runCli(["vantage", "validate", rsDir, "--json"])
  assert.equal(rsVal.code, 0, rsVal.stderr)
  assert.equal(JSON.parse(rsVal.stdout).worker_kind, "rust-worker")

  const rsSrpack = join(workDir, "demo-rs-alpr.srpack")
  const rsBuild = await runCli(["pack", "build", rsDir, "-o", rsSrpack, "--json"])
  assert.equal(rsBuild.code, 0, rsBuild.stderr)
  assert.equal((await runCli(["pack", "validate", rsSrpack])).code, 0)
})

test("vantage init rejects unknown templates and non-empty directories without --force", async () => {
  const workDir = await mkdtemp(join(tmpdir(), "sr-vantage-neg-init-"))

  const badTmpl = await runCli(
    ["vantage", "init", "bad-pack", "--template", "unknown-template"],
    {cwd: workDir},
  )
  assert.notEqual(badTmpl.code, 0)
  assert.match(badTmpl.stderr, /unknown vantage template/)

  const existingDir = join(workDir, "existing-pack")
  await mkdir(existingDir, {recursive: true})
  await writeFile(join(existingDir, "README.md"), "existing\n")

  const refuseNonEmpty = await runCli(
    ["vantage", "init", "existing-pack", "--template", "vlm"],
    {cwd: workDir},
  )
  assert.notEqual(refuseNonEmpty.code, 0)
  assert.match(refuseNonEmpty.stderr, /not empty/)

  const allowForce = await runCli(
    ["vantage", "init", "existing-pack", "--template", "vlm", "--force"],
    {cwd: workDir},
  )
  assert.equal(allowForce.code, 0, allowForce.stderr)

  // Digit-leading project name with --with-dashboard derives a valid lowercase-alpha dashboard slug
  const digitInit = await runCli(
    ["vantage", "init", "123-alpr", "--template", "vlm", "--with-dashboard", "--json"],
    {cwd: workDir},
  )
  assert.equal(digitInit.code, 0, digitInit.stderr)
  const digitDir = join(workDir, "123-alpr")
  await access(join(digitDir, "dashboard_packages/v-123-alpr-console/manifest.json"))
  await access(join(digitDir, "dashboard_packages/v-123-alpr-console/renderer.js"))

  const digitVal = await runCli(["vantage", "validate", digitDir, "--json"])
  assert.equal(digitVal.code, 0, digitVal.stderr)
  assert.equal(JSON.parse(digitVal.stdout).resource_counts.dashboard_packages, 1)

  const digitSrpack = join(workDir, "123-alpr.srpack")
  const digitBuild = await runCli(["pack", "build", digitDir, "-o", digitSrpack, "--json"])
  assert.equal(digitBuild.code, 0, digitBuild.stderr)
  assert.equal((await runCli(["pack", "validate", digitSrpack])).code, 0)

  // Invalid --package-id fails before creating any partial directory on disk
  const badPkgDir = join(workDir, "never-created-pack")
  const badPkgRes = await runCli(
    ["vantage", "init", "never-created-pack", "--template", "vlm", "--package-id", "123bad.example"],
    {cwd: workDir},
  )
  assert.notEqual(badPkgRes.code, 0)
  await assert.rejects(() => access(badPkgDir))
})

test("vantage validate catches worker secret leaks and tampered dashboard digests", async () => {
  const workDir = await mkdtemp(join(tmpdir(), "sr-vantage-val-"))
  await runCli(["vantage", "init", "py-secret-test", "--template", "python-worker"], {cwd: workDir})
  const pyDir = join(workDir, "py-secret-test")

  const leakedToken = "ghp_" + "SyntheticWorkerSecret1234"
  await writeFile(
    join(pyDir, "worker/main.py"),
    `TOKEN = ${JSON.stringify(leakedToken)}\n`,
  )
  const secretRes = await runCli(["vantage", "validate", pyDir])
  assert.notEqual(secretRes.code, 0)
  assert.match(secretRes.stderr, /secret_token_literal/)

  await runCli(["vantage", "init", "dash-tamper", "--template", "vlm", "--with-dashboard"], {
    cwd: workDir,
  })
  const dashDir = join(workDir, "dash-tamper")
  await writeFile(
    join(dashDir, "dashboard_packages/dash-tamper-console/renderer.js"),
    "export function mountDashboard() { return { modified: true }; }\n",
  )
  const tamperRes = await runCli(["vantage", "validate", dashDir])
  assert.notEqual(tamperRes.code, 0)
  assert.match(tamperRes.stderr, /!= actual renderer SHA-256/)
})

test("vantage dev runs offline against synthetic JSON and media clip fixtures and enforces schema bounds", async () => {
  const workDir = await mkdtemp(join(tmpdir(), "sr-vantage-dev-"))
  const initRes = await runCli(
    ["vantage", "init", "gate-west-alpr", "--template", "vlm"],
    {cwd: workDir},
  )
  assert.equal(initRes.code, 0, initRes.stderr)
  const projDir = join(workDir, "gate-west-alpr")

  // 1. JSON fixture run
  const jsonDev = await runCli(
    ["vantage", "dev", projDir, "--fixture", join(projDir, "fixtures/synthetic_frame.json"), "--json"],
  )
  assert.equal(jsonDev.code, 0, jsonDev.stderr)
  const jsonOut = JSON.parse(jsonDev.stdout)
  assert.equal(jsonOut.status, "ok")
  assert.equal(jsonOut.valid, true)
  assert.equal(jsonOut.requires_cluster, false)
  assert.equal(jsonOut.observation_count, 1)
  assert.equal(jsonOut.observations[0].attributes.plate_text, "SR-0100")

  // 2. Binary synthetic .mp4 clip run (no cluster required)
  const syntheticMp4 = join(workDir, "synthetic_gate_west_01.mp4")
  await writeFile(syntheticMp4, Buffer.from("000000186674797069736f6d0000020069736f6d69736f32", "hex"))
  const clipDev = await runCli(
    ["vantage", "dev", "--dir", projDir, "--fixture", syntheticMp4, "--json"],
  )
  assert.equal(clipDev.code, 0, clipDev.stderr)
  const clipOut = JSON.parse(clipDev.stdout)
  assert.equal(clipOut.status, "ok")
  assert.equal(clipOut.requires_cluster, false)

  // 3. Missing or omitted --fixture fails closed
  const missingFlag = await runCli(["vantage", "dev", projDir])
  assert.notEqual(missingFlag.code, 0)
  assert.match(missingFlag.stderr, /--fixture/)

  const missingFile = await runCli(["vantage", "dev", projDir, "--fixture", "/nonexistent/synthetic-missing.mp4"])
  assert.notEqual(missingFile.code, 0)

  const emptyFile = join(workDir, "empty.mp4")
  await writeFile(emptyFile, Buffer.alloc(0))
  const emptyRes = await runCli(["vantage", "dev", projDir, "--fixture", emptyFile])
  assert.notEqual(emptyRes.code, 0)

  // 4. Schema-violating observation attributes fail validation
  const badAttrFixture = join(workDir, "bad-attributes.json")
  await writeFile(
    badAttrFixture,
    JSON.stringify({
      attributes: {
        plate_text: "invalid lowercase plate!",
        unexpected_extra_field: true,
      },
    }),
  )
  const badAttrRes = await runCli(["vantage", "dev", projDir, "--fixture", badAttrFixture])
  assert.notEqual(badAttrRes.code, 0)
  assert.match(badAttrRes.stderr, /signal_schema validation/)

  // 5. Out-of-bounds bbox fails envelope validation
  const badBboxFixture = join(workDir, "bad-bbox.json")
  await writeFile(
    badBboxFixture,
    JSON.stringify({
      observations: [
        {
          observation_key: "obs-bad-bbox",
          category: "license_plate",
          label: "TEST-742",
          confidence: 0.9,
          bbox: [0.8, 0.2, 0.3, 0.5],
          attributes: {plate_text: "TEST-742"},
        },
      ],
    }),
  )
  const badBboxRes = await runCli(["vantage", "dev", projDir, "--fixture", badBboxFixture])
  assert.notEqual(badBboxRes.code, 0)
  assert.match(badBboxRes.stderr, /x1 < x2/)

  // 6. Custom --exec harness reads VantageFrameContext from stdin and emits vantage.result.v1
  const execScript = [
    "const fs = require('node:fs');",
    "const ctx = JSON.parse(fs.readFileSync(0, 'utf8'));",
    "console.log(JSON.stringify({",
    "  schema_version: 'vantage.result.v1',",
    "  worker_kind: 'external_python',",
    "  source_mode: ctx.source_mode,",
    "  observations: [{",
    "    observation_key: 'obs-exec-1',",
    "    category: 'license_plate',",
    "    label: 'TEST-742',",
    "    confidence: 0.97,",
    "    bbox: [0.3, 0.5, 0.5, 0.7],",
    "    attributes: { plate_text: 'TEST-742', camera_label: 'Gate West 01', confidence: 0.97 }",
    "  }]",
    "}));",
  ].join(" ")
  const execDev = await runCli(
    [
      "vantage",
      "dev",
      projDir,
      "--fixture",
      syntheticMp4,
      "--exec",
      `${JSON.stringify(process.execPath)} -e ${JSON.stringify(execScript)}`,
      "--json",
    ],
  )
  assert.equal(execDev.code, 0, execDev.stderr)
  const execOut = JSON.parse(execDev.stdout)
  assert.equal(execOut.status, "ok")
  assert.equal(execOut.worker_kind, "external_python")
  assert.equal(execOut.observations[0].attributes.plate_text, "TEST-742")

  // Verify the scaffolded README uses synthetic data only
  const readme = await readFile(join(projDir, "README.md"), "utf8")
  assert.match(readme, /Gate West 01/)
  const st = await stat(join(projDir, "manifest.json"))
  assert.ok(st.size > 0)
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

test("vantage validate accepts the shipped io.serviceradar.vantage-alpr reference pack", async () => {
  const packDir = resolveVantageAlprPackDir()
  const res = await runCli(["vantage", "validate", packDir, "--json"])
  assert.equal(res.code, 0, res.stderr)
  const parsed = JSON.parse(res.stdout)
  assert.equal(parsed.valid, true)
  assert.equal(parsed.pack_format_version, 2)
  assert.equal(parsed.id, "io.serviceradar.vantage-alpr")
  assert.equal(parsed.slug, "vantage-alpr")
  assert.equal(parsed.worker_kind, "vlm")
  assert.deepEqual(parsed.resource_counts, {
    checks: 1,
    rules: 1,
    dashboards: 1,
    vantage_pipelines: 1,
    signal_schemas: 1,
    dashboard_packages: 1,
  })
})
