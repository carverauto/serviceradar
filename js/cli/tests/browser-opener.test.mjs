import assert from "node:assert/strict"
import {access, chmod, mkdtemp, readFile, writeFile} from "node:fs/promises"
import {constants} from "node:fs"
import {tmpdir} from "node:os"
import {delimiter, join} from "node:path"
import {execFile} from "node:child_process"
import {promisify} from "node:util"
import test from "node:test"

const execFileAsync = promisify(execFile)
const openerUrl = new URL("../dist/utils.js", import.meta.url).href
const opener = "#!/bin/sh\nif [ \"$1\" = \"url.dll,FileProtocolHandler\" ]; then printf '%s' \"$2\" > \"$RESULT_PATH\"; else printf '%s' \"$1\" > \"$RESULT_PATH\"; fi\n"

async function runOpenerCase(dir, platform) {
  const resultPath = join(dir, `argument-${platform}.txt`)
  const injectedPath = join(dir, `shell-expanded-${platform}`)
  const url = `https://example.test/$(touch '${injectedPath}')`
  const script =
    `Object.defineProperty(process, "platform", {value: ${JSON.stringify(platform)}}); ` +
    `const {openBrowser} = await import(${JSON.stringify(openerUrl)}); ` +
    `await openBrowser(${JSON.stringify(url)})`

  await execFileAsync(process.execPath, ["--input-type=module", "--eval", script], {
    env: {...process.env, PATH: `${dir}${delimiter}${process.env.PATH || ""}`, RESULT_PATH: resultPath},
  })

  assert.equal(await readFile(resultPath, "utf8"), url)
  await assert.rejects(access(injectedPath, constants.F_OK), {code: "ENOENT"})
}

test(
  "browser opener passes an untrusted URL as one literal argument",
  {skip: process.platform === "win32" ? "shell shims need a POSIX host" : undefined},
  async (t) => {
    const dir = await mkdtemp(join(tmpdir(), "sr-cli-browser-"))

    for (const name of ["open", "xdg-open", "rundll32"]) {
      const path = join(dir, name)
      await writeFile(path, opener)
      await chmod(path, 0o755)
    }

    for (const platform of ["darwin", "win32", "linux"]) {
      await t.test(`on ${platform}`, () => runOpenerCase(dir, platform))
    }
  },
)
