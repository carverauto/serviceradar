// `serviceradar vantage` subcommand group dispatcher.

import {devCommand} from "./dev.js"
import {initCommand} from "./init.js"
import {validateCommand} from "./validate.js"

export async function dispatchVantage(
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
    case "dev":
      return devCommand(options)
    case "help":
    case "--help":
    case "-h":
      printHelp()
      return
    default:
      throw new Error(`unknown subcommand: vantage ${subcommand}\n\nRun \`serviceradar-cli help\` for usage.`)
  }
}
