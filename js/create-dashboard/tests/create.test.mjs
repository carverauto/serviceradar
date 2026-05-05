import assert from "node:assert/strict"
import {execFile} from "node:child_process"
import {mkdtemp, readFile, stat} from "node:fs/promises"
import {tmpdir} from "node:os"
import {join} from "node:path"
import {promisify} from "node:util"
import test from "node:test"

const execFileAsync = promisify(execFile)
const createBin = new URL("../bin/create.js", import.meta.url)

test("create-dashboard scaffolds a project by forwarding to dashboard init", async () => {
  const workDir = await mkdtemp(join(tmpdir(), "sr-create-dashboard-"))
  const projectName = "scaffold-demo"

  const {stdout} = await execFileAsync(
    process.execPath,
    [createBin.pathname, projectName, "--template", "react-blank", "--no-install", "--package-id", "com.example.scaffold"],
    {cwd: workDir},
  )

  assert.match(stdout, /Scaffolding scaffold-demo from template "react-blank"/)
  assert.match(stdout, /Wrote scaffold-demo\//)

  const projectDir = join(workDir, projectName)
  const projectStat = await stat(projectDir)
  assert.equal(projectStat.isDirectory(), true)

  const pkg = JSON.parse(await readFile(join(projectDir, "package.json"), "utf8"))
  assert.equal(pkg.name, projectName)
  assert.match(pkg.scripts.dev, /serviceradar-cli dashboard dev/)

  const config = await readFile(join(projectDir, "dashboard.config.mjs"), "utf8")
  assert.match(config, /com\.example\.scaffold/)
})

test("create-dashboard rejects unknown templates with a helpful error", async () => {
  const workDir = await mkdtemp(join(tmpdir(), "sr-create-dashboard-"))

  await assert.rejects(
    execFileAsync(
      process.execPath,
      [createBin.pathname, "bogus", "--template", "no-such-template", "--no-install"],
      {cwd: workDir},
    ),
    (err) => {
      assert.match(err.stderr || err.stdout || "", /unknown template/i)
      return true
    },
  )
})
