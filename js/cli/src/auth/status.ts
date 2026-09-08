// `auth status` — print the resolved instance, user, and timestamps for
// each stored credential. The token itself is never written to stdout.

import {normalizeInstanceUrl, readCredentials} from "./credentials.js"

export async function authStatusCommand(options: Record<string, unknown>): Promise<void> {
  const store = readCredentials()
  const instances = store.instances || {}
  const filter = normalizeInstanceUrl(options.instance)

  const entries = Object.entries(instances)
  if (entries.length === 0) {
    console.log("No stored credentials.")
    console.log("→ run `serviceradar-cli auth login --instance <url>` to authenticate.")
    return
  }

  for (const [url, entry] of entries) {
    if (filter && filter !== url) continue
    console.log(`Instance: ${url}`)
    console.log(`  user:        ${entry?.user || "(unknown)"}`)
    console.log(`  obtained_at: ${entry?.obtained_at || "(unknown)"}`)
    console.log(`  expires_at:  ${entry?.expires_at || "(no expiry recorded)"}`)
  }
}
