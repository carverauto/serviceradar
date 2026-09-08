import {ensureK8sAlertsCommand} from "./ensure_k8s_alerts.js"

export async function dispatchNotifications(
  subcommand: string,
  options: Record<string, unknown>,
  printHelp: () => void,
): Promise<void> {
  switch (subcommand) {
    case "ensure-k8s-alerts":
      return ensureK8sAlertsCommand(options)
    case "help":
    case "--help":
    case "-h":
      printHelp()
      return
    default:
      throw new Error(
        `unknown subcommand: notifications ${subcommand}\n\nRun \`serviceradar-cli help\` for usage.`,
      )
  }
}
