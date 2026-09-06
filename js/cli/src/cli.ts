#!/usr/bin/env node
// `serviceradar-cli` entry. Owns: top-level argv parse, group dispatch
// (auth / dashboard / doctor / version / help), and the help text. Each
// command's implementation lives in its own module under `src/`.

import {parseArgs} from "./args.js"
import {dispatchAuth} from "./auth/index.js"
import {dispatchDashboard} from "./dashboard/index.js"
import {doctorCommand, printVersion} from "./doctor.js"
import {dispatchNotifications} from "./notifications/index.js"
import {dispatchPlugin} from "./plugin/index.js"
import {describeError, ensureExtraCaCertificates} from "./tls_ca.js"

main().catch((error: any) => {
  console.error(describeError(error))
  process.exitCode = 1
})

async function main(): Promise<void> {
  ensureExtraCaCertificates()
  const argv = process.argv.slice(2)
  const [first = "help", ...rest] = argv

  if (first === "help" || first === "--help" || first === "-h") {
    printHelp()
    return
  }

  if (first === "--version" || first === "-v" || first === "version") {
    printVersion()
    return
  }

  if (first === "doctor") {
    return doctorCommand(parseArgs(rest))
  }

  if (first === "auth") {
    const [authSub = "help", ...authRest] = rest
    const options = parseArgs(authRest)
    return dispatchAuth(authSub, options)
  }

  if (first === "notifications") {
    const [notifySub = "help", ...notifyRest] = rest
    const options = parseArgs(notifyRest)
    return dispatchNotifications(notifySub, options, printHelp)
  }

  if (first === "plugin") {
    const [pluginSub = "help", ...pluginRest] = rest
    const options = parseArgs(pluginRest)
    return dispatchPlugin(pluginSub, options, printHelp)
  }

  if (first === "dashboard") {
    const [dashSub = "help", ...dashRest] = rest
    const options = parseArgs(dashRest)
    return dispatchDashboard(dashSub, options, printHelp)
  }

  // Backward-compat: top-level command routes to the `dashboard` group
  // so existing scripts that call `serviceradar-dashboard build` keep
  // working through the transitional alias bin.
  const options = parseArgs(rest)
  return dispatchDashboard(first, options, printHelp)
}

function printHelp(): void {
  console.log(`ServiceRadar CLI

Usage:
  serviceradar-cli <group> <subcommand> [...flags]
  serviceradar-cli --version
  serviceradar-cli doctor

Groups:
  auth        Authenticate against a ServiceRadar instance and manage stored credentials.
  dashboard   Author and operate ServiceRadar dashboard packages.
  plugin         Author and publish ServiceRadar Wasm plugins.
  notifications  Configure notification routes against a ServiceRadar instance.

Top-level commands:
  --version   Print the installed @carverauto/serviceradar-cli version.
  doctor      Print runtime + project diagnostics (Node, npm, SDK, Vite, config path, auth state).

Common dashboard subcommands:
  serviceradar-cli dashboard init <name> [--template react-map|react-table|react-blank] [--package-id com.example.foo] [--no-install]
  serviceradar-cli dashboard build [--config dashboard.config.mjs] [--out-dir dist]
  serviceradar-cli dashboard manifest [--config dashboard.config.mjs] [--out-dir dist]
  serviceradar-cli dashboard validate [--config dashboard.config.mjs]
  serviceradar-cli dashboard dev [--config dashboard.config.mjs] [--port 4177] [--no-hmr] [--no-build] [--open] [--mapbox-token pk.…]
  serviceradar-cli dashboard publish --instance <url> [--route <slug>] [--token <bearer>] [--enable] [--yes]
  serviceradar-cli dashboard import [--config dashboard.config.mjs] [--exec "command"]

Notification subcommands:
  serviceradar-cli notifications ensure-k8s-alerts --instance <url> [--channel demo-discord] [--token <bearer>] [--fire-test | --clear-test]
    --fire-test opens a synthetic node incident; --clear-test resolves it once the Discord page has arrived. They cannot be combined.

Plugin subcommands:
  serviceradar-cli plugin init <name> [--template go|rust] [--plugin-id my-plugin] [--force]
  serviceradar-cli plugin validate [--manifest plugin.yaml] [--wasm plugin.wasm]
  serviceradar-cli plugin publish --instance <url> [--token <bearer>] [--wasm plugin.wasm] [--yes]
  serviceradar-cli plugin status --instance <url> --id <package-id>
  serviceradar-cli plugin assignments|secrets|rules|controllers <list|get|create|update|enable|disable> --instance <url>
  serviceradar-cli plugin apply --instance <url> --file playbooks/demo-plugins.yaml [--dry-run]

Auth subcommands:
  serviceradar-cli auth login   --instance <url> [--no-browser] [--ca-file <pem>] [--token <existing-token>]
  serviceradar-cli auth status  [--instance <url>]
  serviceradar-cli auth logout  [--instance <url>]

Commands:
  init      Scaffold a new dashboard package from a template. Copies the
            chosen template, swizzles project name + identifier, runs npm
            install, and prints next steps. Templates: react-map (default —
            useDeckMap reference), react-table (frame-driven table),
            react-blank (minimum viable).
  build     Build renderer.js with SDK Vite defaults, write manifest, and copy samples.
            Runs validate first; refuses to write dist/ on validation failure.
  manifest  Compute renderer SHA256 and write dist/manifest.json.
  validate  Static check: dashboard.config.mjs shape, manifest required fields,
            samples.frames against declared data_frames, samples.settings against
            settings_schema. No build, no network.
  dev       Serve the dashboard against the SDK harness with HMR. Vite middleware
            mode imports the renderer entry directly so source edits remount the
            renderer without a page reload. Pass --no-hmr for the legacy build-once
            harness, --open to open the browser, --mapbox-token to override the
            sample-settings token.
  import    Verify manifest/artifact and optionally run a local import command.

Plugin commands:
  init      Scaffold a Wasm plugin project. Templates: go (default, builds with
            TinyGo against serviceradar-sdk-go) and rust (wasm32-wasip1 against
            serviceradar-sdk-rust).
  validate  Static check of plugin.yaml against the manifest contract, plus the
            built plugin.wasm if present. No build, no network.
  publish   Stage the built plugin on an instance and upload its bundle. The
            package lands staged; an administrator approves it before agents run
            it. Needs a token carrying the \`plugin.publish\` scope.
  status    Read a staged package back to see whether it has been approved, and
            which capabilities were approved.
  apply     Idempotent gitops apply of plugin assignments, credential secrets,
            credential rules, and Ansible controllers from a YAML playbook.
            Secret values are read from environment variables named in the
            playbook; they are never stored in git. Needs \`plugins.manage\`.
`)
}
