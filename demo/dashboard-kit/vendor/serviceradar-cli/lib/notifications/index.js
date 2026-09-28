import { ensureK8sAlertsCommand } from "./ensure_k8s_alerts.js";
export async function dispatchNotifications(subcommand, options, printHelp) {
    switch (subcommand) {
        case "ensure-k8s-alerts":
            return ensureK8sAlertsCommand(options);
        case "help":
        case "--help":
        case "-h":
            printHelp();
            return;
        default:
            throw new Error(`unknown subcommand: notifications ${subcommand}\n\nRun \`serviceradar-cli help\` for usage.`);
    }
}
//# sourceMappingURL=index.js.map