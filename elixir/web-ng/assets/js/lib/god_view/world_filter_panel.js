import {worldJson} from "./world_http"

const CONTROL = "rounded-sr-control border border-sr-line bg-sr-control px-2 py-1.5 text-sm text-sr-ink outline-none focus-visible:ring-2 focus-visible:ring-sr-focus"
const BUTTON = `${CONTROL} font-semibold hover:border-sr-line-hover disabled:opacity-50`
let panelSequence = 0

function node(tag, className = "", text = "") {
  const value = document.createElement(tag)
  value.className = className
  value.textContent = text
  return value
}

function button(text, action) {
  const value = node("button", BUTTON, text)
  value.type = "button"
  value.addEventListener("click", action)
  return value
}

function labeled(text, input) {
  const label = node("label", "flex min-w-0 flex-col gap-1 text-xs text-sr-muted")
  label.append(node("span", "", text), input)
  input.setAttribute("aria-label", text)
  return label
}

function select(values, selected, change) {
  const control = node("select", `${CONTROL} min-w-0 w-full`)
  for (const [value, text, disabled = false] of values) {
    const option = node("option", "", text)
    option.value = value
    option.disabled = disabled
    control.append(option)
  }
  control.value = selected
  control.addEventListener("change", () => change(control.value))
  return control
}

function group(children = []) {return {mode: "all", children, exclude: false}}

function fromExpression(expression) {
  if (expression.except) {
    const child = fromExpression(expression.except)
    return {...child, exclude: !child.exclude}
  }
  if (expression.all || expression.any) return {mode: expression.all ? "all" : "any", children: (expression.all || expression.any).map(fromExpression), exclude: false}
  if (expression.ip_cidr) return {field: "$ip", value: expression.ip_cidr}
  if (expression.prefix_tag) return {field: "$prefix_tag", source: expression.prefix_tag.source, value: expression.prefix_tag.label}
  if (expression.tag_key_prefix) return {field: "$tag_keys", value: expression.tag_key_prefix,
    operator: expression.prefix !== undefined ? "prefix" : expression.value !== undefined ? "eq" : "present", tagValue: expression.prefix ?? expression.value ?? ""}
  return {field: expression.facet, value: expression.prefix ?? expression.value ?? "", operator: expression.prefix !== undefined ? "prefix" : "eq"}
}

/** Bounded control metadata only; fleet membership remains in binary overlays. */
export class WorldFilterPanel {
  constructor({parent, toolbar, onApply}) {
    Object.assign(this, {parent, toolbar, onApply})
    this.lifetime = new AbortController()
    this.state = {}
    this.draft = group([this.condition()])
    this.button = button("Filters", () => this.toggle())
    this.button.setAttribute("aria-label", "Topology filters")
    this.button.setAttribute("aria-expanded", "false")
    this.panel = node("section", "absolute left-3 z-30 rounded-lg border border-sr-line bg-sr-surface p-3 text-sm text-sr-ink shadow-sr-control")
    this.panel.id = `topology-filters-${++panelSequence}`
    this.panel.hidden = true
    this.panel.style.width = "min(34rem, calc(100% - 1.5rem))"
    this.panel.style.overflowY = "auto"
    this.panel.setAttribute("role", "dialog")
    this.panel.setAttribute("aria-label", "Topology filters")
    this.button.setAttribute("aria-controls", this.panel.id)
    const heading = node("div", "mb-3 flex items-center justify-between gap-3")
    heading.append(node("h3", "text-base font-semibold", "Filter devices"), button("Close filters", () => this.close()))
    this.status = node("p", "mb-3 text-sm text-sr-muted")
    this.status.setAttribute("aria-live", "polite")
    this.tree = node("div", "space-y-3")
    this.error = node("p", "mt-3 text-sm text-sr-ink empty:hidden")
    this.error.setAttribute("role", "alert")
    this.apply = button("Apply filters", () => this.submit())
    const clear = button("Clear filters", () => {
      this.draft = group([this.condition()])
      this.error.textContent = ""
      this.onApply(null)
      this.renderTree()
    })
    const actions = node("div", "mt-4 flex flex-wrap gap-2")
    actions.append(this.apply, clear)
    this.help = node("p", "mt-3 text-xs leading-relaxed text-sr-muted",
      "Filtered links are hidden when an aggregate or boundary cannot provide exact matching relations. Clear filters to restore all base-map links.")
    this.panel.append(heading, this.status, this.tree, this.error, actions, this.help)
    toolbar.append(this.button)
    parent.append(this.panel)
    document.addEventListener("pointerdown", event => {
      if (!this.panel.hidden && !this.panel.contains(event.target) && !this.button.contains(event.target)) this.close(false)
    }, {signal: this.lifetime.signal})
    document.addEventListener("keydown", event => {
      if (!this.panel.hidden && event.key === "Escape") {event.preventDefault(); this.close()}
    }, {signal: this.lifetime.signal})
    this.update({})
  }

  condition() {return {field: this.descriptor?.facets?.[0]?.key || "", operator: "eq", value: "", exclude: false}}

  update(state) {
    Object.assign(this.state, state)
    const descriptor = this.state.capability?.query
    const descriptorKey = JSON.stringify(descriptor ?? null)
    const queryKey = JSON.stringify(this.state.query ?? null)
    let redraw = this.descriptorKey !== descriptorKey
    this.descriptor = descriptor
    this.descriptorKey = descriptorKey
    if (this.queryKey !== undefined && this.queryKey !== queryKey) {
      const current = this.state.query ? fromExpression(this.state.query) : group([this.condition()])
      this.draft = current.children ? current : group([current])
      redraw = true
    }
    this.queryKey = queryKey
    if (redraw) this.renderTree()
    const ready = this.state.enabled && descriptor && this.state.capability?.ready !== false
    this.apply.disabled = !ready
    this.button.textContent = this.state.query ? "Filters active" : "Filters"
    this.help.hidden = !this.state.query
    this.status.textContent = !descriptor ? "Device filtering is unavailable on this server." :
      !ready ? `Filters are unavailable: ${this.state.capability?.reason?.replaceAll("_", " ") || (this.state.enabled ? "index preparing" : "filtering disabled")}.` :
        this.state.error ? `Filter unavailable: ${this.state.error.replaceAll("_", " ")}.` :
          this.state.query && this.state.pending ? "Updating matching devices…" :
            this.state.query && this.state.total !== null && this.state.total !== undefined ? `Applied filter: ${new Intl.NumberFormat().format(this.state.total)} matching devices` :
              "Choose inventory fields or tags. Values match exactly unless you choose starts with."
  }

  toggle() {
    if (!this.panel.hidden) return this.close()
    const top = this.toolbar.offsetTop + this.toolbar.offsetHeight + 8
    this.panel.style.top = `${top}px`
    this.panel.style.maxHeight = `calc(100% - ${top + 32}px)`
    this.panel.hidden = false
    this.button.setAttribute("aria-expanded", "true")
    this.panel.querySelector("select, input, button")?.focus()
  }

  close(focus = true) {
    this.panel.hidden = true
    this.button.setAttribute("aria-expanded", "false")
    this.cancelDiscovery()
    if (focus) this.button.focus()
  }

  cancelDiscovery() {this.discovery?.abort(); this.discovery = null}

  renderTree() {
    this.cancelDiscovery()
    this.tree.replaceChildren(this.renderNode(this.draft))
  }

  renderNode(term, parent = null, depth = 0) {
    const box = node("fieldset", "min-w-0 space-y-2 rounded border border-sr-line p-2")
    const tools = node("div", "flex flex-wrap items-center gap-2")
    const exclude = node("input")
    exclude.type = "checkbox"
    exclude.checked = term.exclude === true
    exclude.addEventListener("change", () => {term.exclude = exclude.checked})
    const exclusion = labeled("Exclude (EXCEPT)", exclude)
    exclusion.className = "inline-flex items-center gap-2 text-xs text-sr-muted"
    if (term.children) {
      tools.append(select([["all", "Match all (AND)"], ["any", "Match any (OR)"]], term.mode, mode => {term.mode = mode}), exclusion)
      tools.firstChild.setAttribute("aria-label", "Group match")
      tools.firstChild.className = `${CONTROL} min-w-0 flex-1`
    } else tools.append(exclusion)
    if (parent) tools.append(button(term.children ? "Remove group" : "Remove condition", () => {
      parent.children.splice(parent.children.indexOf(term), 1)
      this.renderTree()
    }))
    box.append(tools)
    if (term.children) {
      for (const child of term.children) box.append(this.renderNode(child, term, depth + 1))
      const add = node("div", "flex flex-wrap gap-2")
      const condition = button("Add condition", () => {term.children.push(this.condition()); this.renderTree()})
      const nested = button("Add group", () => {term.children.push(group([this.condition()])); this.renderTree()})
      const bounded = this.conditionCount() >= 32
      condition.disabled = bounded || this.nodeCount() >= 65
      nested.disabled = bounded || this.nodeCount() >= 64 || depth >= 6
      add.append(condition, nested)
      box.append(add)
    } else this.renderCondition(term, box)
    return box
  }

  conditionCount(term = this.draft) {return term.children ? term.children.reduce((sum, child) => sum + this.conditionCount(child), 0) : 1}

  nodeCount(term = this.draft) {return 1 + (term.children?.reduce((sum, child) => sum + this.nodeCount(child), 0) || 0)}

  renderCondition(term, box) {
    const facets = this.descriptor?.facets || []
    if (!term.field) term.field = facets[0]?.key || ""
    const choices = facets.map(facet => [facet.key, facet.label])
    choices.push(["$tag_keys", `Device tag names start with${this.descriptor?.operators?.tag_key_prefix ? "" : " (unavailable)"}`, !this.descriptor?.operators?.tag_key_prefix],
      ["$ip", `IP / CIDR${this.descriptor?.operators?.ip_cidr ? "" : " (unavailable)"}`, !this.descriptor?.operators?.ip_cidr])
    if (this.descriptor?.prefix_tags) choices.push(["$prefix_tag", "Named Prefix Tag", !this.descriptor.prefix_tags.available])
    if (!choices.some(([key]) => key === term.field)) choices.unshift([term.field, "Unavailable field", true])
    const field = select(choices, term.field, value => {
      Object.assign(term, {field: value, operator: value === "$tag_keys" ? "present" : "eq", value: "", source: "", tagValue: ""})
      this.renderTree()
    })
    const fields = node("div", term.field === "$ip" || term.field === "$prefix_tag" || term.field === "$tag_keys" ? "grid gap-2" :
      "grid grid-cols-1 gap-2 sm:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)_minmax(0,1fr)]")
    fields.append(labeled("Filter field", field))
    box.append(fields)
    if (term.field === "$prefix_tag") return this.renderPrefixTag(term, fields)
    const scalar = facets.find(facet => facet.key === term.field)
    if (term.field !== "$ip") {
      const operators = term.field === "$tag_keys" ? [["present", "Has a matching tag"], ["eq", "Tag value equals"], ["prefix", "Tag value starts with"]] :
        [["eq", "Equals"], ["prefix", "Starts with", !scalar?.operators?.includes("prefix")]]
      fields.append(labeled("Match", select(operators, term.operator || "eq", value => {term.operator = value; this.renderTree()})))
    }
    fields.append(this.textInput(term, "value", term.field === "$ip" ? "IP network" : term.field === "$tag_keys" ? "Tag name prefix" : "Value"))
    if (term.field === "$tag_keys" && term.operator !== "present") box.append(this.textInput(term, "tagValue", "Tag value"))
    const hint = term.field === "$ip" ? "Matches any current device or interface address. Use numeric IPv4 or IPv6 CIDR, such as 192.0.2.0/24." :
      term.field === "$tag_keys" || term.operator === "prefix" ? "Starts with is literal and case-sensitive; no wildcards or regular expressions." :
        term.field === "vlan" ? "Canonical inventory VLAN assignment; this does not identify every VLAN carried on a switch port." :
          term.field === "device_class" ? "Use the canonical numeric device class value." : ""
    if (hint) {
      field.title = hint
      if (term.field !== "vlan") box.append(node("p", "text-xs leading-relaxed text-sr-muted", hint))
    }
  }

  textInput(term, key, label) {
    const input = node("input", `${CONTROL} w-full`)
    input.type = "text"
    input.maxLength = 256
    input.value = term[key] || ""
    input.addEventListener("input", () => {term[key] = input.value})
    return labeled(label, input)
  }

  renderPrefixTag(term, box) {
    const catalog = this.descriptor?.prefix_tags
    if (!catalog) {
      box.append(node("p", "text-xs text-sr-muted", "Named Prefix Tags are unavailable on this server."))
      return
    }
    const sources = catalog.sources || []
    if (!term.source) term.source = sources.find(source => source.available)?.source || ""
    const source = select(sources.map(item => [item.source, item.available ? item.source : `${item.source} (unavailable)`, !item.available]), term.source, value => {
      term.source = value; term.value = ""; this.renderTree()
    })
    const labels = select([[term.value || "", term.value || "Load labels to choose"]], term.value || "", value => {term.value = value})
    const message = node("p", "text-xs text-sr-muted", "Labels belong to the selected local Prefix Tags source.")
    const next = button("Next labels", () => void load(next.cursor))
    next.hidden = true
    const load = async cursor => {
      this.cancelDiscovery()
      const controller = new AbortController()
      this.discovery = controller
      message.textContent = "Loading labels…"
      next.disabled = true
      try {
        const url = new URL(catalog.discovery_url, window.location.href)
        if (url.origin !== window.location.origin || url.pathname !== "/topology/query/prefix-tags") throw new Error("Unsupported label catalog")
        url.searchParams.set("source", term.source)
        url.searchParams.set("limit", "50")
        if (cursor) url.searchParams.set("cursor", cursor)
        const result = await worldJson(url.toString(), controller.signal, 131072)
        if (controller.signal.aborted || this.discovery !== controller || !labels.isConnected) return
        if (result.source !== term.source || !Number.isSafeInteger(result.version) || result.version < 0 ||
            !Array.isArray(result.labels) || result.labels.length > 50 || result.labels.some(value => typeof value !== "string" || !value || new TextEncoder().encode(value).length > 256) ||
            (result.cursor !== null && (typeof result.cursor !== "string" || result.cursor.length > 4096))) throw new Error("Invalid label catalog")
        const options = [...new Set([term.value, ...result.labels].filter(Boolean))]
        labels.replaceChildren(...[["", "Choose a label"], ...options.map(value => [value, value])].map(([value, text]) => {
          const option = node("option", "", text); option.value = value; return option
        }))
        labels.value = term.value || ""
        next.cursor = result.cursor; next.hidden = !result.cursor; next.disabled = false
        message.textContent = `${result.labels.length} labels in this page. Source version ${result.version}.`
      } catch (error) {
        if (!controller.signal.aborted) message.textContent = `Labels unavailable: ${error.message}. Reload labels to try again.`
      }
    }
    box.append(labeled("Prefix Tags source", source), labeled("Prefix Tag label", labels), button("Load labels", () => void load()), next, message)
  }

  expression(term = this.draft, depth = 0, budget = {predicates: 0, nodes: 0}) {
    if (depth > 8 || ++budget.nodes > 65) throw new Error("Use fewer nested groups (maximum depth 8).")
    if (term.exclude) return {except: this.expression({...term, exclude: false}, depth + 1, budget)}
    if (term.children) {
      if (!term.children.length) throw new Error("Add a condition to each group, or clear filters.")
      return {[term.mode]: term.children.map(child => this.expression(child, depth + 1, budget))}
    }
    if (++budget.predicates > 32) throw new Error("Use at most 32 conditions.")
    const value = term.field === "$prefix_tag" ? term.value || "" : (term.value || "").trim()
    if (!value || new TextEncoder().encode(value).length > 256) throw new Error("Each condition needs a value of at most 256 bytes.")
    if (term.field === "$ip" && this.descriptor?.operators?.ip_cidr) return {ip_cidr: value}
    if (term.field === "$prefix_tag" && this.descriptor?.prefix_tags?.available && this.descriptor.prefix_tags.sources.some(source => source.source === term.source && source.available)) return {prefix_tag: {source: term.source, label: value}}
    if (term.field === "$tag_keys" && this.descriptor?.operators?.tag_key_prefix) {
      if (term.operator === "present") return {tag_key_prefix: value}
      const tagValue = (term.tagValue || "").trim()
      if (!tagValue || new TextEncoder().encode(tagValue).length > 256) throw new Error("Enter a tag value to match.")
      return {tag_key_prefix: value, [term.operator === "prefix" ? "prefix" : "value"]: tagValue}
    }
    const facet = this.descriptor?.facets?.find(item => item.key === term.field)
    if (!facet?.operators.includes(term.operator)) throw new Error("This field or operator is unavailable on the server.")
    return {facet: term.field, [term.operator === "prefix" ? "prefix" : "value"]: value}
  }

  submit() {
    try {
      if (this.apply.disabled) return
      const expression = this.expression()
      if (new TextEncoder().encode(JSON.stringify(expression)).length > 16384) throw new Error("Filter exceeds the query size limit.")
      this.error.textContent = ""
      this.onApply(expression)
    } catch (error) {this.error.textContent = error.message}
  }

  destroy() {this.cancelDiscovery(); this.lifetime.abort(); this.panel.remove(); this.button.remove()}
}
