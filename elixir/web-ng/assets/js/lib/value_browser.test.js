import {Window} from "happy-dom"
import {afterEach, beforeEach, expect, it, vi} from "vitest"
import {ValueBrowser, ValuePicker} from "./value_browser"
import Hook from "../hooks/ValueBrowser"

let browser, view
const tick = () => new Promise(resolve => setTimeout(resolve, 0))
const choose = value => document.querySelector(`input[aria-label="${value}"]`).click()
const button = name => [...document.querySelectorAll("button")].find(el => el.textContent === name)

beforeEach(() => {
  browser = new Window({url: "https://example.test/devices"})
  vi.stubGlobal("window", browser)
  vi.stubGlobal("document", browser.document)
})
afterEach(() => {view?.destroy?.(); view?.close?.(); browser.happyDOM.abort(); vi.unstubAllGlobals()})

it("pages the Devices dictionary, preserves navigable links and filters beyond the first page", async () => {
  const host = document.createElement("div")
  host.dataset.items = JSON.stringify(Array.from({length: 60}, (_, i) => ({value: `Example vendor ${i + 1}`, count: i + 1, href: `/devices?q=vendor-${i + 1}`})))
  document.body.append(host)
  const hook = {el: host}
  Hook.mounted.call(hook)
  view = hook.browser
  await tick()
  expect(host.querySelectorAll("a")).toHaveLength(50)
  button("Next").click(); await tick()
  expect(host.querySelectorAll("a")).toHaveLength(10)
  expect(host.querySelector("a").getAttribute("href")).toBe("/devices?q=vendor-51")
  button("First").click(); await tick()
  expect(host.querySelector("a").getAttribute("href")).toBe("/devices?q=vendor-1")
  expect(button("First").disabled).toBe(true)
  view.search.value = "VENDOR 59"
  view.search.dispatchEvent(new browser.Event("input"))
  await new Promise(resolve => setTimeout(resolve, 250))
  expect(host.querySelectorAll("a")).toHaveLength(1)
  expect(host.querySelector("a").textContent).toContain("Example vendor 59")
  expect(button("Previous").disabled).toBe(true)
  expect(button("Next").disabled).toBe(true)
})

it("keeps exact selections across pages and search, ignores stale replies, and retries errors", async () => {
  const pending = []
  const accept = vi.fn()
  view = new ValueBrowser({parent: document.body, selected: [], onConfirm: accept, onCancel: vi.fn(),
    load: args => new Promise((resolve, reject) => pending.push({...args, resolve, reject}))})
  pending[0].resolve({items: [{value: "Example A", count: 4}], cursor: "page-two"}); await tick()
  choose("Example A")
  button("Next").click()
  expect(pending[1].cursor).toBe("page-two")
  pending[1].resolve({items: [{value: "Example B", count: 8}], cursor: null}); await tick()
  choose("Example B")
  button("Use 2 selected values").click()
  expect(accept).toHaveBeenCalledWith(["Example A", "Example B"])
  button("Previous").click()
  view.search.value = "C"
  view.search.dispatchEvent(new browser.Event("input"))
  expect(pending[2].signal.aborted).toBe(true)
  document.querySelector('[aria-label="Remove Example A"]').click()
  expect(view.list.querySelectorAll("input")).toHaveLength(0)
  pending[2].resolve({items: [{value: "Stale", count: 1}], cursor: null})
  await new Promise(resolve => setTimeout(resolve, 250))
  expect(pending[3].cursor).toBe(null)
  pending[3].reject(new Error("query_busy")); await tick()
  expect(view.error.textContent).toBe("query_busy")
  button("Retry").click()
  pending[4].resolve({items: [], cursor: "later-window"}); await tick()
  expect(view.summary.textContent).toContain("Continue with Next")
  expect(button("Next").disabled).toBe(false)
  button("Use 1 selected value").click()
  expect(accept).toHaveBeenLastCalledWith(["Example B"])
})

it("opens a modal, cancels in-flight discovery and restores focus without accepting changes", async () => {
  const trigger = document.createElement("button")
  document.body.append(trigger); trigger.focus()
  const accept = vi.fn(), close = vi.fn()
  let signal
  view = new ValuePicker({title: "Choose vendor values", trigger, onClose: close, selected: ["Example A"], onConfirm: accept,
    load: args => {signal = args.signal; return new Promise(() => {})}})
  expect(view.dialog.open).toBe(true)
  expect(document.activeElement).toBe(view.browser.search)
  view.dialog.dispatchEvent(new browser.Event("cancel", {cancelable: true}))
  expect(signal.aborted).toBe(true)
  expect(accept).not.toHaveBeenCalled()
  expect(close).toHaveBeenCalledOnce()
  expect(document.activeElement).toBe(trigger)
  expect(document.querySelector("dialog")).toBe(null)
})
