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

export async function worldJson(url, signal, limit = 262144) {
  const deadline = globalThis.AbortSignal.timeout(15000)
  const response = await fetch(url, {credentials: "same-origin", signal: signal ? globalThis.AbortSignal.any([signal, deadline]) : deadline, headers: {Accept: "application/json"}})
  if (!response.ok) throw new Error(`Topology HTTP ${response.status}`)
  return JSON.parse(new TextDecoder().decode(await readBoundedBody(response, limit)))
}
