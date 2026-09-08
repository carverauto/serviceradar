import {mkdtemp, readFile, rm} from "node:fs/promises"
import {tmpdir} from "node:os"
import {join} from "node:path"

import {afterEach, describe, expect, it} from "vitest"

import {createAcceptanceTimeline} from "./god_view_acceptance_timeline.js"

const temporaryDirectories = []

async function temporaryTimeline() {
  const directory = await mkdtemp(join(tmpdir(), "god-view-acceptance-timeline-"))
  temporaryDirectories.push(directory)
  return join(directory, "timings.jsonl")
}

async function recordsAt(path) {
  try {
    return (await readFile(path, "utf8"))
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line))
  } catch (error) {
    if (error.code === "ENOENT") return []
    throw error
  }
}

afterEach(async () => {
  await Promise.all(temporaryDirectories.splice(0).map((directory) => (
    rm(directory, {recursive: true, force: true})
  )))
})

describe("God-View acceptance timeline", () => {
  it("persists the active step before running it and appends its measured completion", async () => {
    const path = await temporaryTimeline()
    const clock = [100, 112.5]
    const measure = createAcceptanceTimeline({
      path,
      now: () => clock.shift(),
      log: () => {},
    })

    const result = await measure("render collapsed", async () => {
      expect(await recordsAt(path)).toEqual([
        {event: "start", step: "render collapsed"},
      ])
      return {elapsedMs: 7.5, snapshot: {profileKey: "landscape"}}
    }, ({elapsedMs}) => ({rendererElapsedMs: elapsedMs}))

    expect(result.snapshot.profileKey).toBe("landscape")
    expect(await recordsAt(path)).toEqual([
      {event: "start", step: "render collapsed"},
      {
        detail: {rendererElapsedMs: 7.5},
        elapsedMs: 12.5,
        event: "end",
        step: "render collapsed",
      },
    ])
  })

  it("records a failed step before rethrowing the original error", async () => {
    const path = await temporaryTimeline()
    const clock = [200, 205]
    const measure = createAcceptanceTimeline({
      path,
      now: () => clock.shift(),
      log: () => {},
    })
    const failure = new Error("renderer exploded")

    await expect(measure("render concurrent", async () => {
      throw failure
    })).rejects.toBe(failure)

    expect(await recordsAt(path)).toEqual([
      {event: "start", step: "render concurrent"},
      {
        elapsedMs: 5,
        error: "Error: renderer exploded",
        event: "error",
        step: "render concurrent",
      },
    ])
  })
})
