// `dashboard validate` — surface the same static checks the build invokes
// pre-flight, lifted into a standalone command so authors can run them
// without bundling. Sets `process.exitCode = 1` on failure so CI scripts
// see the non-zero exit.

import {resolve} from "node:path"

import {loadConfig} from "../config.js"
import {formatValidationFailures, validateProject} from "../validation.js"

export async function validateCommand(options: Record<string, any>): Promise<void> {
  const projectDir = resolve(options.cwd || process.cwd())
  const config = options.configObject || await loadConfig(projectDir, options.config)
  const result = await validateProject(projectDir, config, {skipDigestCheck: true})

  if (result.failures.length === 0) {
    console.log("Dashboard config validates.")
    if (result.notes.length > 0) {
      for (const note of result.notes) console.log(`  • ${note}`)
    }
    return
  }

  console.error(formatValidationFailures(result.failures))
  process.exitCode = 1
}
