// `serviceradar-cli edge ...` dispatch + help.

import {parseArgs} from "../args.js"
import {dispatchEdgeInstall} from "./install.js"
import {dispatchEdgePackage} from "./packages.js"
import {dispatchEdgeSite} from "./sites.js"

export {dispatchAgent} from "./agents.js"
export {dispatchCollector, dispatchNats} from "./collectors.js"

export async function dispatchEdge(argv: string[]): Promise<void> {
  const [group = "help", sub = "help", ...rest] = argv
  if (group === "help" || group === "--help" || group === "-h") {
    printEdgeHelp()
    return
  }
  if (sub === "help" || sub === "--help" || sub === "-h") {
    printEdgeHelp()
    return
  }
  const options = parseArgs(rest)
  switch (group) {
    case "package":
      return dispatchEdgePackage(sub, options)
    case "site":
      return dispatchEdgeSite(sub, options)
    case "install":
      return dispatchEdgeInstall(sub, options)
    default:
      throw new Error(`unknown subcommand: edge ${group}\n\nRun \`serviceradar-cli edge help\` for usage.`)
  }
}

export function printEdgeHelp(): void {
  console.log(`Usage:
  Edge packages (agent/gateway onboarding):
    serviceradar-cli edge package create   --instance <url> --label <name> [--component-type agent|gateway|checker|sync]
                                           [--gateway-id <id>] [--site <partition>] [--security-mode mtls|spire] [--json]
    serviceradar-cli edge package list     --instance <url> [--status <s>] [--component-type <t>] [--json]
    serviceradar-cli edge package show     <id> --instance <url> [--json]
    serviceradar-cli edge package revoke   <id> --instance <url> [--reason <text>] [--json]
    serviceradar-cli edge package download <id> --instance <url> --token <onboarding-token> [-o file]

  Edge sites (local NATS leaf per site):
    serviceradar-cli edge site create --instance <url> --name <name> [--slug <slug>] [--json]
    serviceradar-cli edge site list   --instance <url> [--json]
    serviceradar-cli edge site show   <id> --instance <url> [--json]
    serviceradar-cli edge site bundle <id> --instance <url> [-o file] [--wait] [--timeout 600] [--interval 5]

  Edge host install helpers (run as root on the edge host; --dry-run prints the plan):
    serviceradar-cli edge install agent     --instance <url> --package <id> --token <onboarding-token> --version <release>
    serviceradar-cli edge install leaf      --instance <url> --site <id> [--version <release>]
    serviceradar-cli edge install collector --instance <url> --id <id> --token <enrollment-token> [--version <release>] [--type <t>]
      common: [--format rpm|deb] [--arch x86_64|aarch64] [--release-base-url <url>] [--release-api-url <url>] [--bundle-dir <dir>] [--dry-run]

Every command except \`package download\`, \`install agent\` and \`collector download\`
needs a CLI token carrying the edge.manage scope (\`serviceradar-cli auth login\`
requests it by default). Install helpers that call the API take an explicit
bearer through --api-token, because their --token is the onboarding token.

\`edge package download\` marks the package delivered: its token cannot then be
used by \`edge install agent\`. Use one or the other.

--instance can also come from SERVICERADAR_INSTANCE. --version pins a GitHub
release (e.g. 1.4.81). It is required for \`edge install agent\`. Leaf and
collector installs omit it to download the matching package from the latest
release. A collector bound to an edge site is configured only after the local
serviceradar-nats service is active, and it writes to that leaf.`)
}
