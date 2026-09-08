// `auth logout` — remove a stored credential. With `--instance` we target
// that one entry. Without it we remove the only-stored entry and refuse
// when multiple are stored, asking the user to disambiguate.

import {deleteStoredCredential, normalizeInstanceUrl, readCredentials} from "./credentials.js"

export async function authLogoutCommand(options: Record<string, unknown>): Promise<void> {
  const filter = normalizeInstanceUrl(options.instance)
  if (filter) {
    const removed = deleteStoredCredential(filter)
    console.log(removed ? `✓ Removed credential for ${filter}` : `No credential stored for ${filter}`)
    return
  }

  const store = readCredentials()
  const urls = Object.keys(store.instances || {})
  if (urls.length === 0) {
    console.log("No stored credentials to remove.")
    return
  }
  if (urls.length === 1) {
    deleteStoredCredential(urls[0])
    console.log(`✓ Removed credential for ${urls[0]}`)
    return
  }
  throw new Error(`multiple credentials stored — pass --instance to disambiguate. Stored:\n  ${urls.join("\n  ")}`)
}
