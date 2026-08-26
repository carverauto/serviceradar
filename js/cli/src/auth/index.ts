// `serviceradar-cli auth` subcommand group: dispatch + help.

import {authLoginCommand} from "./login.js"
import {authStatusCommand} from "./status.js"
import {authLogoutCommand} from "./logout.js"

export {resolveCredentialToken} from "./credentials.js"

export async function dispatchAuth(
  subcommand: string,
  options: Record<string, unknown>,
): Promise<void> {
  switch (subcommand) {
    case "login":
      return authLoginCommand(options)
    case "status":
      return authStatusCommand(options)
    case "logout":
      return authLogoutCommand(options)
    case "help":
    case "--help":
    case "-h":
      printAuthHelp()
      return
    default:
      throw new Error(`unknown subcommand: auth ${subcommand}\n\nRun \`serviceradar-cli auth help\` for usage.`)
  }
}

export function printAuthHelp(): void {
  console.log(`Usage:
  serviceradar-cli auth login   --instance <url> [--web] [--no-browser] [--ca-file <pem>] [--token <existing-token>]
  serviceradar-cli auth status  [--instance <url>]
  serviceradar-cli auth logout  [--instance <url>]

Reads/writes ~/.config/serviceradar/credentials.json (mode 0600).

Private / corporate CAs:
  Node does not use the OS trust store. If curl works but login fails with
  UNABLE_TO_GET_ISSUER_CERT_LOCALLY, put the issuer PEM at
  ~/.config/serviceradar/ca-bundle.pem, or pass --ca-file / set
  SERVICERADAR_CA_FILE or NODE_EXTRA_CA_CERTS.

Login flows:
  default        OAuth 2.0 Device Authorization Grant (RFC 8628). The CLI
                 prints a verification URL + user code, optionally opens
                 the browser, and polls until the user completes login.
  --web          OAuth 2.0 Authorization Code with PKCE (RFC 7636 / RFC
                 8252). The CLI starts a localhost callback server,
                 opens the instance's authorize endpoint in a browser,
                 and exchanges the returned code for a long-lived token.

Both flows fall back to manual token paste when the corresponding
endpoints return 404. TLS and network failures are reported instead of
that fallback.`)
}
