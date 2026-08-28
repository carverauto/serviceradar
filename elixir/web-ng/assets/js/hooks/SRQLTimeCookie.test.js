import {afterEach, beforeEach, describe, expect, test} from "vitest"

import SRQLTimeCookie from "./SRQLTimeCookie"

const rememberedRange =
  "[2026-08-27T03:00:00Z,2026-08-27T10:59:59.999999Z]"

function eventTarget() {
  const listeners = new Map()

  return {
    addEventListener(name, listener) {
      listeners.set(name, listener)
    },
    removeEventListener(name) {
      listeners.delete(name)
    },
  }
}

function mount(query, {search = ""} = {}) {
  const input = {...eventTarget(), value: query}
  const form = {
    ...eventTarget(),
    dataset: {query},
    querySelector(selector) {
      return selector === 'input[name="q"]' ? input : null
    },
  }

  globalThis.window.location.search = search
  globalThis.document.cookie = `srql_time=${encodeURIComponent(rememberedRange)}`

  const hook = Object.create(SRQLTimeCookie)
  hook.el = form
  hook.mounted()

  return {hook, input}
}

describe("SRQLTimeCookie hook", () => {
  beforeEach(() => {
    globalThis.window = {location: {search: ""}}
    globalThis.document = {activeElement: null, cookie: ""}
  })

  afterEach(() => {
    delete globalThis.window
    delete globalThis.document
  })

  test.each([
    ["device index", "in:devices include_inactive:true"],
    [
      "device detail",
      'in:devices uid:"sr:device-1" include_deleted:true limit:50',
    ],
  ])("does not inject remembered time into %s", (_name, query) => {
    const {hook, input} = mount(query)

    expect(input.value).toBe(query)

    hook.destroyed()
  })

  test("replaces the window on a query that is already temporal", () => {
    const query = "in:events time:last_24h sort:time:desc limit:20"
    const {hook, input} = mount(query)

    expect(input.value).toBe(
      `in:events time:${rememberedRange} sort:time:desc limit:20`,
    )

    hook.destroyed()
  })

  test("keeps an explicit deep-linked time window authoritative", () => {
    const query = "in:events time:last_7d sort:time:desc limit:20"
    const {hook, input} = mount(query, {search: "?q=in%3Aevents"})

    expect(input.value).toBe(query)
    expect(globalThis.document.cookie).toContain("srql_time=last_7d;")

    hook.destroyed()
  })
})
