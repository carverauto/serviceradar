// `serviceradar pack` subcommand group dispatcher.

import {buildCommand} from "./build.js"
import {indexCommand} from "./index_cmd.js"
import {keygenCommand, signCommand, verifyCommand} from "./sign.js"
import {validateCommand} from "./validate.js"

export async function dispatchPack(
  subcommand: string,
  options: Record<string, unknown>,
  printHelp: () => void,
): Promise<void> {
  switch (subcommand) {
    case "validate":
      return validateCommand(options)
    case "build":
      return buildCommand(options)
    case "keygen":
      return keygenCommand(options)
    case "sign":
      return signCommand(options)
    case "verify":
      return verifyCommand(options)
    case "index":
      return indexCommand(options)
    case "help":
    case "--help":
    case "-h":
      printHelp()
      return
    default:
      throw new Error(`unknown subcommand: pack ${subcommand}\n\nRun \`serviceradar help\` for usage.`)
  }
}
