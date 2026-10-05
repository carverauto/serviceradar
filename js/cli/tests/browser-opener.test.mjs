import assert from "node:assert/strict"
import {access, chmod, mkdtemp, readFile, writeFile} from "node:fs/promises"
import {constants} from "node:fs"
import {tmpdir} from "node:os"
import {join} from "node:path"
import {execFile} from "node:child_process"
import {promisify} from "node:util"
import test from "node:test"

const execFileAsync = promisify(execFile)

test("browser opener passes an untrusted URL as one literal argument", async () => {
  const dir = await mkdtemp(join(tmpdir(), "sr-cli-browser-"))
  const resultPath = join(dir, "argument.txt")
  const injectedPath = join(dir, "shell-expanded")
  const opener = "#!/bin/sh\nprintf '%s' \"$1\" > \"$RESULT_PATH\"\n"

  for (const name of ["open", "xdg-open", "rundll32"]) {
    const path = join(dir, name)
    await writeFile(path, opener)
    await chmod(path, 0o755)
  }

  const url = `https://example.test/$(touch '${injectedPath}')`
  const script = `import {openBrowser} from ${JSON.stringify(new URL("../dist/utils.js", import.meta.url).href)}; await openBrowser(${JSON.stringify(url)})`

  await execFileAsync(process.execPath, ["--input-type=module", "--eval", script], {
    env: {...process.env, PATH: `${dir}:${process.env.PATH || ""}`, RESULT_PATH: resultPath},
  })

  assert.equal(await readFile(resultPath, "utf8"), url)
  await assert.rejects(access(injectedPath, constants.F_OK), {code: "ENOENT"})
})
