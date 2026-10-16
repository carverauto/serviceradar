import {Window} from "happy-dom"
import {afterEach, beforeEach, describe, expect, it, vi} from "vitest"
import {WorldFilterPanel} from "./world_filter_panel"

const capability = {ready: true, query: {
  entity_kind: "device", facets: [
    {key: "vlan", label: "Inventory VLAN", operators: ["eq"]},
    {key: "tag:owner", label: "Device tag: owner", operators: ["eq", "prefix"]},
  ], tag_keys: ["owner"], operators: {tag_key_prefix: true, ip_cidr: true},
  prefix_tags: {available: true, discovery_url: "/topology/query/prefix-tags",
    sources: ["synthetic-east", "synthetic-west"].map(source => ({source, version: 1, available: true}))},
}}
let panel, onApply, browser
const controls = label => [...document.querySelectorAll(`[aria-label="${label}"]`)]
function edit(label, value, index = 0) {
  const input = controls(label)[index]
  input.value = value
  input.dispatchEvent(new browser.Event(input.tagName === "SELECT" ? "change" : "input", {bubbles: true}))
}
function click(label, index = 0) {
  const button = [...document.querySelectorAll("button")].filter(item => item.textContent === label)[index]
  button.click()
}
function check(index) {
  const input = controls("Exclude (EXCEPT)")[index]
  input.checked = true
  input.dispatchEvent(new browser.Event("change", {bubbles: true}))
}
beforeEach(() => {
  browser = new Window({url: "https://topology.example.test/topology"})
  vi.stubGlobal("window", browser)
  vi.stubGlobal("document", browser.document)
  const root = document.createElement("div"), toolbar = document.createElement("form")
  document.body.append(root); root.append(toolbar)
  onApply = vi.fn()
  panel = new WorldFilterPanel({parent: root, toolbar, onApply})
  panel.update({enabled: true, capability, query: null, pending: false, total: null})
  click("Filters")
})
afterEach(() => {panel.destroy(); browser.happyDOM.abort(); vi.unstubAllGlobals()})

describe("topology device filter controls", () => {
  it("builds nested AND/OR with unary EXCEPT, exact inventory VLAN, literal tags and any-address CIDR", () => {
    edit("Value", "320")
    click("Add group")
    edit("Group match", "any", 1)
    edit("Filter field", "$ip", 1)
    edit("IP network", "192.0.2.0/24")
    click("Add condition", 0) // The nested group's controls precede the root's.
    edit("Filter field", "tag:owner", 2)
    edit("Match", "prefix", 1)
    edit("Value", "Synthetic", 1)
    check(4)
    click("Apply filters")
    expect(onApply).toHaveBeenLastCalledWith({all: [{facet: "vlan", value: "320"}, {any: [
      {ip_cidr: "192.0.2.0/24"}, {except: {facet: "tag:owner", prefix: "Synthetic"}},
    ]}]})
    panel.update({query: onApply.mock.calls.at(-1)[0], pending: true})
    expect(panel.panel.textContent).toContain("Updating matching devices")
    expect(panel.panel.textContent).toContain("Filtered links are hidden")
    panel.update({pending: false, total: 12003})
    expect(panel.panel.textContent).toContain("12,003 matching devices")
    panel.update({pending: true, total: null})
    expect(panel.panel.textContent).not.toContain("12,003 matching devices")
    click("Clear filters")
    expect(onApply).toHaveBeenLastCalledWith(null)
    document.dispatchEvent(new browser.KeyboardEvent("keydown", {key: "Escape", bubbles: true}))
    expect(panel.panel.hidden).toBe(true)
    expect(document.activeElement).toBe(panel.button)
  })

  it("keeps paired tag predicates on one key and preserves a query after editing double exclusion", () => {
    edit("Filter field", "$tag_keys")
    edit("Tag name prefix", "role.")
    edit("Match", "prefix")
    edit("Tag value", "access")
    click("Apply filters")
    expect(onApply).toHaveBeenLastCalledWith({all: [{tag_key_prefix: "role.", prefix: "access"}]})
    panel.update({query: {except: {except: {facet: "vlan", value: "320"}}}})
    click("Apply filters")
    expect(onApply).toHaveBeenLastCalledWith({all: [{facet: "vlan", value: "320"}]})
  })

  it("blocks unsupported fields, absent readiness and invalid drafts while keeping Clear usable", () => {
    panel.update({capability: {...capability, ready: false, reason: "index_not_ready"}})
    edit("Value", "320")
    click("Apply filters")
    expect(onApply).not.toHaveBeenCalled()
    expect(panel.panel.textContent).toContain("index not ready")
    panel.update({capability: {...capability, query: {...capability.query, operators: {}}}})
    expect(controls("Filter field")[0].querySelector('[value="$ip"]').disabled).toBe(true)
    edit("Match", "prefix") // A stale restored operator is rejected even if UI disabling is bypassed.
    click("Apply filters")
    expect(onApply).not.toHaveBeenCalled()
    expect(panel.error.textContent).toContain("unavailable")
    edit("Match", "eq"); edit("Value", "")
    click("Apply filters")
    expect(panel.error.textContent).toContain("needs a value")
    panel.update({query: {facet: "vlan", value: "320"}, error: "unsupported_predicate", total: null})
    expect(panel.status.textContent).toContain("unsupported predicate")
    click("Clear filters")
    expect(onApply).toHaveBeenLastCalledWith(null)
    panel.update({query: {prefix_tag: {source: "synthetic-east", label: "Synthetic Access"}}})
    panel.update({capability: undefined, enabled: false})
    expect(panel.status.textContent).toContain("unavailable")
    expect(panel.apply.disabled).toBe(true)
    click("Clear filters")
    expect(onApply).toHaveBeenLastCalledWith(null)
  })

  it("pages named Prefix Tags separately, bounds the catalog and rejects stale source replies", async () => {
    const requests = []
    vi.stubGlobal("fetch", vi.fn((url, options) => new Promise(resolve => requests.push({url: new URL(url), options, resolve}))))
    edit("Filter field", "$prefix_tag")
    click("Load labels")
    expect(requests[0].url.pathname).toBe("/topology/query/prefix-tags")
    expect(requests[0].url.searchParams.get("limit")).toBe("50")
    edit("Prefix Tags source", "synthetic-west")
    expect(requests[0].options.signal.aborted).toBe(true)
    click("Load labels")
    requests[1].resolve(Response.json({source: "synthetic-west", version: 2, labels: ["Synthetic Access", "Synthetic Transit"], cursor: "synthetic-next"}))
    await vi.waitFor(() => expect(controls("Prefix Tag label")[0].options.length).toBe(3))
    requests[0].resolve(Response.json({source: "synthetic-east", version: 1, labels: ["Stale label"], cursor: null}))
    edit("Prefix Tag label", "Synthetic Access")
    click("Next labels")
    expect(requests[2].url.searchParams.get("cursor")).toBe("synthetic-next")
    requests[2].resolve(Response.json({source: "synthetic-west", version: 2, labels: [" Synthetic Edge "], cursor: null}))
    await vi.waitFor(() => expect(controls("Prefix Tag label")[0].textContent).toContain(" Synthetic Edge "))
    expect(controls("Prefix Tag label")[0].textContent).not.toContain("Synthetic Transit")
    expect(controls("Prefix Tag label")[0].textContent).not.toContain("Stale label")
    edit("Prefix Tag label", " Synthetic Edge ")
    click("Apply filters")
    expect(onApply).toHaveBeenLastCalledWith({all: [{prefix_tag: {source: "synthetic-west", label: " Synthetic Edge "}}]})
    click("Load labels")
    requests[3].resolve(Response.json({source: "synthetic-west", version: 2, labels: Array(51).fill("Too many"), cursor: null}))
    await vi.waitFor(() => expect(panel.panel.textContent).toContain("Invalid label catalog"))
    expect(controls("Prefix Tag label")[0].textContent).not.toContain("Too many")
    click("Load labels")
    panel.destroy()
    expect(requests[4].options.signal.aborted).toBe(true)
  })
})
