export async function readBoundedBody(response, limit) {
  if (Number(response.headers.get("content-length")) > limit) {
    await response.body?.cancel()
    throw new Error("Topology payload exceeds byte budget")
  }
  const reader = response.body?.getReader()
  if (!reader) {
    const bytes = await response.arrayBuffer()
    if (bytes.byteLength > limit) throw new Error("Topology payload exceeds byte budget")
    return new Uint8Array(bytes)
  }
  const chunks = []
  let length = 0
  try {
    for (;;) {
      const {done, value} = await reader.read()
      if (done) break
      length += value.byteLength
      if (length > limit) {
        await reader.cancel()
        throw new Error("Topology payload exceeds byte budget")
      }
      chunks.push(value)
    }
  } finally {
    reader.releaseLock()
  }
  const bytes = new Uint8Array(length)
  let offset = 0
  for (const chunk of chunks) {
    bytes.set(chunk, offset)
    offset += chunk.byteLength
  }
  return bytes
}

export const TOPOLOGY_GET_URL_LIMIT = 8000

function boundedQuery(params) {
  const query = new URLSearchParams()
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined && value !== null) query.set(key, String(value))
  }
  return query
}

export function topologyTarget(path, params) {
  const query = boundedQuery(params)
  return {query, target: query.size ? `${path}?${query}` : path}
}

export async function worldExchange(path, params, {signal, accept = "application/json", csrfToken = ""} = {}) {
  const {query, target} = topologyTarget(path, params)
  const post = target.length > TOPOLOGY_GET_URL_LIMIT
  const deadline = globalThis.AbortSignal.timeout(15000)
  const headers = {Accept: accept}
  const init = {
    credentials: "same-origin",
    method: post ? "POST" : "GET",
    signal: signal ? globalThis.AbortSignal.any([signal, deadline]) : deadline,
    headers,
  }
  if (post) {
    headers["content-type"] = "application/json"
    headers["x-csrf-token"] = csrfToken
    init.body = JSON.stringify(Object.fromEntries(query))
  }
  return {response: await fetch(post ? path : target, init), target, post}
}

export async function worldJson(url, signal, limit = 262144) {
  const deadline = globalThis.AbortSignal.timeout(15000)
  const response = await fetch(url, {credentials: "same-origin", signal: signal ? globalThis.AbortSignal.any([signal, deadline]) : deadline, headers: {Accept: "application/json"}})
  if (!response.ok) throw new Error(`Topology HTTP ${response.status}`)
  return JSON.parse(new TextDecoder().decode(await readBoundedBody(response, limit)))
}

export async function worldJsonParams(path, params, options = {}) {
  const {response} = await worldExchange(path, params, options)
  if (!response.ok) throw new Error(`Topology HTTP ${response.status}`)
  return JSON.parse(new TextDecoder().decode(await readBoundedBody(response, options.limit ?? 262144)))
}
