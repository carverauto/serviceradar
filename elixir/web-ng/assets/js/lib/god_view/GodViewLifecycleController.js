import {godViewLifecycleMethods} from "./lifecycle_methods"

const LIFECYCLE_CONTROLLER_SHARED_METHODS = [
  "ensureDeck",
]

const LIFECYCLE_CONTROLLER_CONTEXT_METHODS = [
  "mounted",
  "destroyed",
  "initLifecycleState",
  "bindLifecycleMethods",
  "attachLifecycleDom",
  "initWasmEngine",
  "registerLifecycleEvents",
  "registerFilterEvent",
  "registerZoomModeEvent",
  "registerLayerEvents",
  "setupSnapshotChannel",
  "ensureGodViewSocket",
  "registerSnapshotChannelEvents",
  "joinSnapshotChannel",
  "cleanupLifecycle",
  "cleanupLifecycleDomListeners",
  "cleanupLifecycleRuntime",
  "startAnimationLoop",
  "stopAnimationLoop",
  "handlePanStart",
  "handlePanMove",
  "handlePanEnd",
  "handleWheelZoom",
  "ensureDOM",
  "resizeCanvas",
  "createDeckInstance",
  "ensureDeck",
  "handleSnapshot",
  "parseSnapshotMessage",
  "base64ToArrayBuffer",
  "parseBinarySnapshotFrame",
  "startPolling",
  "stopPolling",
  "pollSnapshot",
  "decodeArrowGraph",
]

function bindApiMethods(instance, methods) {
  return Object.fromEntries(methods.map((method) => [method, instance[method].bind(instance)]))
}

export default class GodViewLifecycleController {
  constructor(context) {
    this.context = context
  }

  getContextApi() {
    return bindApiMethods(this, LIFECYCLE_CONTROLLER_CONTEXT_METHODS)
  }

  getSharedApi() {
    return bindApiMethods(this, LIFECYCLE_CONTROLLER_SHARED_METHODS)
  }

  mount() {
    if (typeof this.mounted === "function") this.mounted()
  }

  destroy() {
    if (typeof this.destroyed === "function") this.destroyed()
  }

  mounted(...args) {
    return godViewLifecycleMethods.mounted.call(this.context, ...args)
  }

  destroyed(...args) {
    return godViewLifecycleMethods.destroyed.call(this.context, ...args)
  }

  initLifecycleState(...args) {
    return godViewLifecycleMethods.initLifecycleState.call(this.context, ...args)
  }

  bindLifecycleMethods(...args) {
    return godViewLifecycleMethods.bindLifecycleMethods.call(this.context, ...args)
  }

  attachLifecycleDom(...args) {
    return godViewLifecycleMethods.attachLifecycleDom.call(this.context, ...args)
  }

  initWasmEngine(...args) {
    return godViewLifecycleMethods.initWasmEngine.call(this.context, ...args)
  }

  registerLifecycleEvents(...args) {
    return godViewLifecycleMethods.registerLifecycleEvents.call(this.context, ...args)
  }

  registerFilterEvent(...args) {
    return godViewLifecycleMethods.registerFilterEvent.call(this.context, ...args)
  }

  registerZoomModeEvent(...args) {
    return godViewLifecycleMethods.registerZoomModeEvent.call(this.context, ...args)
  }

  registerLayerEvents(...args) {
    return godViewLifecycleMethods.registerLayerEvents.call(this.context, ...args)
  }

  setupSnapshotChannel(...args) {
    return godViewLifecycleMethods.setupSnapshotChannel.call(this.context, ...args)
  }

  ensureGodViewSocket(...args) {
    return godViewLifecycleMethods.ensureGodViewSocket.call(this.context, ...args)
  }

  registerSnapshotChannelEvents(...args) {
    return godViewLifecycleMethods.registerSnapshotChannelEvents.call(this.context, ...args)
  }

  joinSnapshotChannel(...args) {
    return godViewLifecycleMethods.joinSnapshotChannel.call(this.context, ...args)
  }

  cleanupLifecycle(...args) {
    return godViewLifecycleMethods.cleanupLifecycle.call(this.context, ...args)
  }

  cleanupLifecycleDomListeners(...args) {
    return godViewLifecycleMethods.cleanupLifecycleDomListeners.call(this.context, ...args)
  }

  cleanupLifecycleRuntime(...args) {
    return godViewLifecycleMethods.cleanupLifecycleRuntime.call(this.context, ...args)
  }

  startAnimationLoop(...args) {
    return godViewLifecycleMethods.startAnimationLoop.call(this.context, ...args)
  }

  stopAnimationLoop(...args) {
    return godViewLifecycleMethods.stopAnimationLoop.call(this.context, ...args)
  }

  handlePanStart(...args) {
    return godViewLifecycleMethods.handlePanStart.call(this.context, ...args)
  }

  handlePanMove(...args) {
    return godViewLifecycleMethods.handlePanMove.call(this.context, ...args)
  }

  handlePanEnd(...args) {
    return godViewLifecycleMethods.handlePanEnd.call(this.context, ...args)
  }

  handleWheelZoom(...args) {
    return godViewLifecycleMethods.handleWheelZoom.call(this.context, ...args)
  }

  ensureDOM(...args) {
    return godViewLifecycleMethods.ensureDOM.call(this.context, ...args)
  }

  resizeCanvas(...args) {
    return godViewLifecycleMethods.resizeCanvas.call(this.context, ...args)
  }

  createDeckInstance(...args) {
    return godViewLifecycleMethods.createDeckInstance.call(this.context, ...args)
  }

  ensureDeck(...args) {
    return godViewLifecycleMethods.ensureDeck.call(this.context, ...args)
  }

  handleSnapshot(...args) {
    return godViewLifecycleMethods.handleSnapshot.call(this.context, ...args)
  }

  parseSnapshotMessage(...args) {
    return godViewLifecycleMethods.parseSnapshotMessage.call(this.context, ...args)
  }

  base64ToArrayBuffer(...args) {
    return godViewLifecycleMethods.base64ToArrayBuffer.call(this.context, ...args)
  }

  parseBinarySnapshotFrame(...args) {
    return godViewLifecycleMethods.parseBinarySnapshotFrame.call(this.context, ...args)
  }

  startPolling(...args) {
    return godViewLifecycleMethods.startPolling.call(this.context, ...args)
  }

  stopPolling(...args) {
    return godViewLifecycleMethods.stopPolling.call(this.context, ...args)
  }

  pollSnapshot(...args) {
    return godViewLifecycleMethods.pollSnapshot.call(this.context, ...args)
  }

  decodeArrowGraph(...args) {
    return godViewLifecycleMethods.decodeArrowGraph.call(this.context, ...args)
  }
}
