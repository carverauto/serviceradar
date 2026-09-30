import ELK from "elkjs/lib/elk.bundled.js"
import {radialGraph} from "./radial_graph"

// QuickJS supplies a queue rather than browser timers. Drain it alongside promises.
globalThis.window = globalThis
globalThis.global = globalThis
globalThis.console = {error() {}, err() {}, warn() {}, log() {}}
const queue = []
let nextTimer = 0
const cancelled = new Set()
globalThis.setTimeout = callback => {const id = ++nextTimer; queue.push({id, callback}); return id}
globalThis.clearTimeout = id => cancelled.add(id)
globalThis.__srDrain = () => {
  const timer = queue.shift()
  if (timer && !cancelled.delete(timer.id)) timer.callback()
  return queue.length > 0
}
const elk = new ELK()
globalThis.__srLayout = input => {
  globalThis.__srResult = null
  globalThis.__srFailure = null
  const graph = radialGraph(input.nodes, input.edges, {radius: input.radius})
  graph.layoutOptions["org.eclipse.elk.radial.wedgeCriteria"] = "NODE_SIZE"
  elk.layout(graph).then(graph => {
    globalThis.__srResult = JSON.stringify(graph.children.map(node => ({id: node.id, x: node.x + node.width / 2, y: node.y + node.height / 2})))
  }).catch(error => {globalThis.__srFailure = String(error?.message || error)})
}
