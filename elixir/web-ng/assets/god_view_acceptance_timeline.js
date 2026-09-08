import {appendFile} from "node:fs/promises"

function roundedMilliseconds(value) {
  return Math.round(value * 100) / 100
}

async function appendRecord(path, record) {
  await appendFile(path, `${JSON.stringify(record)}\n`, "utf8")
}

export function createAcceptanceTimeline({
  path,
  now = () => performance.now(),
  log = (message) => console.log(message),
}) {
  return async function measure(step, operation, describeResult = () => undefined) {
    const startedAt = now()
    await appendRecord(path, {event: "start", step})
    log(`[god-view] START ${step}`)

    try {
      const result = await operation()
      const elapsedMs = roundedMilliseconds(now() - startedAt)
      const detail = describeResult(result)
      const record = {
        ...(detail === undefined ? {} : {detail}),
        elapsedMs,
        event: "end",
        step,
      }
      await appendRecord(path, record)
      log(`[god-view] END ${step} (${elapsedMs} ms)`)
      return result
    } catch (error) {
      const elapsedMs = roundedMilliseconds(now() - startedAt)
      await appendRecord(path, {
        elapsedMs,
        error: String(error),
        event: "error",
        step,
      })
      log(`[god-view] ERROR ${step} (${elapsedMs} ms): ${String(error)}`)
      throw error
    }
  }
}
