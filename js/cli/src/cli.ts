#!/usr/bin/env node
// `serviceradar-cli` entry. Owns: top-level argv parse, group dispatch
// (auth / dashboard / doctor / version / help), and the help text. Each
// command's implementation lives in its own module under `src/`.

import {parseArgs} from "./args.js"
import {dispatchAuth} from "./auth/index.js"
import {dispatchDashboard} from "./dashboard/index.js"
import {doctorCommand, printVersion} from "./doctor.js"
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
`)
}
