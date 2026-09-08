// Browser-local recent SRQL queries for the query bar (Chrome address-bar style).
// Cap matches issue #4852 ("last 10~").

export const HISTORY_LIMIT = 10
export const HISTORY_STORAGE_KEY = "srql:query-history"

/**
 * @param {Storage | null | undefined} [storage]
 * @returns {string[]}
 */
export function readHistory(storage = defaultStorage()) {
  if (!storage) return []

  try {
    const raw = storage.getItem(HISTORY_STORAGE_KEY)
    if (!raw) return []

    const parsed = JSON.parse(raw)
    if (!Array.isArray(parsed)) return []

    return parsed
      .map(entry => (typeof entry === "string" ? entry.trim() : ""))
      .filter(Boolean)
      .slice(0, HISTORY_LIMIT)
  } catch {
    return []
  }
}

/**
 * Record an executed query. Most recent first; exact duplicates move to front.
 *
 * @param {string} query
 * @param {Storage | null | undefined} [storage]
 * @returns {string[]}
 */
export function pushHistory(query, storage = defaultStorage()) {
  const trimmed = String(query || "").trim()
  if (!trimmed || !storage) return readHistory(storage)

  const next = [trimmed, ...readHistory(storage).filter(entry => entry !== trimmed)].slice(
    0,
    HISTORY_LIMIT
  )

  try {
    storage.setItem(HISTORY_STORAGE_KEY, JSON.stringify(next))
  } catch {
    // Quota / private mode — ignore; history is best-effort.
  }

  return next
}

/**
 * @param {string} [filter]
 * @param {Storage | null | undefined} [storage]
 * @returns {string[]}
 */
export function filterHistory(filter = "", storage = defaultStorage()) {
  const needle = String(filter || "").trim().toLowerCase()
  const history = readHistory(storage)
  if (!needle) return history

  return history.filter(entry => entry.toLowerCase().includes(needle))
}

function defaultStorage() {
  try {
    return globalThis.localStorage
  } catch {
    return null
  }
}
