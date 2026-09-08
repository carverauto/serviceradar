// `serviceradar-cli plugin` subcommand group: dispatcher.
// Help printing is owned by the top-level `printHelp()` in src/cli.ts, matching
// the `dashboard` group, so the whole CLI surface is described in one place.

import {applyCommand} from "./apply.js"
import {dispatchPluginConfig} from "./config.js"
import {initCommand} from "./init.js"
import {publishCommand} from "./publish.js"
import {statusCommand} from "./status.js"
import {validateCommand} from "./validate.js"

export async function dispatchPlugin(
  subcommand: string,
  options: Record<string, unknown>,
  printHelp: () => void,
): Promise<void> {
  switch (subcommand) {
    case "init":
    case "create":
      return initCommand(options)
    case "validate":
      return validateCommand(options)
    case "publish":
      return publishCommand(options)
    case "status":
      return statusCommand(options)
    case "apply":
      return applyCommand(options)
    case "assignments":
    case "secrets":
    case "rules":
    case "controllers":
      return dispatchPluginConfig(subcommand, options)
    case "help":
    case "--help":
    case "-h":
      printHelp()
      return
    default:
      throw new Error(`unknown subcommand: plugin ${subcommand}\n\nRun \`serviceradar-cli help\` for usage.`)
  }
}
