// `serviceradar-cli dashboard` subcommand group: dispatcher.
// Help printing is owned by the top-level `printHelp()` in src/cli.ts so
// the user sees the full CLI surface (auth + dashboard + doctor + version)
// from one place.

import {buildCommand} from "./build.js"
import {devCommand} from "./dev.js"
import {importCommand} from "./import.js"
import {initCommand} from "./init.js"
import {manifestCommand} from "./manifest.js"
import {publishCommand} from "./publish.js"
import {validateCommand} from "./validate.js"

export async function dispatchDashboard(
  subcommand: string,
  options: Record<string, unknown>,
  printHelp: () => void,
): Promise<void> {
  switch (subcommand) {
    case "build":
      return buildCommand(options)
    case "manifest":
      return manifestCommand(options)
    case "validate":
      return validateCommand(options)
    case "init":
    case "create":
      return initCommand(options)
    case "dev":
      return devCommand(options)
    case "publish":
      return publishCommand(options)
    case "import":
      return importCommand(options)
    case "help":
    case "--help":
    case "-h":
      printHelp()
      return
    default:
      throw new Error(`unknown subcommand: dashboard ${subcommand}\n\nRun \`serviceradar-cli help\` for usage.`)
  }
}
