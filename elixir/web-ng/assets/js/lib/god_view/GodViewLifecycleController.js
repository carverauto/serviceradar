import {godViewLifecycleMethods} from "./lifecycle_methods"

import SharedStateAdapter from "./SharedStateAdapter"

const LIFECYCLE_CONTROLLER_SHARED_METHODS = [
  "ensureDeck",
]

function bindApiMethods(instance, methods) {
  return Object.fromEntries(methods.map((method) => [method, instance[method].bind(instance)]))
}

export default class GodViewLifecycleController extends SharedStateAdapter {
  constructor(state) {
    super(state)
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
    return godViewLifecycleMethods.mounted.call(this, ...args)
  }

  destroyed(...args) {
    return godViewLifecycleMethods.destroyed.call(this, ...args)
  }

  initLifecycleState(...args) {
    return godViewLifecycleMethods.initLifecycleState.call(this, ...args)
  }

  bindLifecycleMethods(...args) {
    return godViewLifecycleMethods.bindLifecycleMethods.call(this, ...args)
  }

  attachLifecycleDom(...args) {
    return godViewLifecycleMethods.attachLifecycleDom.call(this, ...args)
  }

  initWasmEngine(...args) {
    return godViewLifecycleMethods.initWasmEngine.call(this, ...args)
  }

  registerLifecycleEvents(...args) {
    return godViewLifecycleMethods.registerLifecycleEvents.call(this, ...args)
  }

  registerFilterEvent(...args) {
    return godViewLifecycleMethods.registerFilterEvent.call(this, ...args)
  }

  registerZoomModeEvent(...args) {
    return godViewLifecycleMethods.registerZoomModeEvent.call(this, ...args)
  }

  registerLayerEvents(...args) {
    return godViewLifecycleMethods.registerLayerEvents.call(this, ...args)
  }

  setupSnapshotChannel(...args) {
    return godViewLifecycleMethods.setupSnapshotChannel.call(this, ...args)
  }

  ensureGodViewSocket(...args) {
    return godViewLifecycleMethods.ensureGodViewSocket.call(this, ...args)
  }

  registerSnapshotChannelEvents(...args) {
    return godViewLifecycleMethods.registerSnapshotChannelEvents.call(this, ...args)
  }

  joinSnapshotChannel(...args) {
    return godViewLifecycleMethods.joinSnapshotChannel.call(this, ...args)
  }

  cleanupLifecycle(...args) {
    return godViewLifecycleMethods.cleanupLifecycle.call(this, ...args)
  }

  cleanupLifecycleDomListeners(...args) {
    return godViewLifecycleMethods.cleanupLifecycleDomListeners.call(this, ...args)
  }

  cleanupLifecycleRuntime(...args) {
    return godViewLifecycleMethods.cleanupLifecycleRuntime.call(this, ...args)
  }

  startAnimationLoop(...args) {
    return godViewLifecycleMethods.startAnimationLoop.call(this, ...args)
  }

  stopAnimationLoop(...args) {
    return godViewLifecycleMethods.stopAnimationLoop.call(this, ...args)
  }

  handlePanStart(...args) {
    return godViewLifecycleMethods.handlePanStart.call(this, ...args)
  }

  handlePanMove(...args) {
    return godViewLifecycleMethods.handlePanMove.call(this, ...args)
  }

  handlePanEnd(...args) {
    return godViewLifecycleMethods.handlePanEnd.call(this, ...args)
  }

  handleWheelZoom(...args) {
    return godViewLifecycleMethods.handleWheelZoom.call(this, ...args)
  }

  ensureDOM(...args) {
    return godViewLifecycleMethods.ensureDOM.call(this, ...args)
  }

  resizeCanvas(...args) {
    return godViewLifecycleMethods.resizeCanvas.call(this, ...args)
  }

  createDeckInstance(...args) {
    return godViewLifecycleMethods.createDeckInstance.call(this, ...args)
  }

  ensureDeck(...args) {
    return godViewLifecycleMethods.ensureDeck.call(this, ...args)
  }

  handleSnapshot(...args) {
    return godViewLifecycleMethods.handleSnapshot.call(this, ...args)
  }

  parseSnapshotMessage(...args) {
    return godViewLifecycleMethods.parseSnapshotMessage.call(this, ...args)
  }

  base64ToArrayBuffer(...args) {
    return godViewLifecycleMethods.base64ToArrayBuffer.call(this, ...args)
  }

  parseBinarySnapshotFrame(...args) {
    return godViewLifecycleMethods.parseBinarySnapshotFrame.call(this, ...args)
  }

  startPolling(...args) {
    return godViewLifecycleMethods.startPolling.call(this, ...args)
  }

  stopPolling(...args) {
    return godViewLifecycleMethods.stopPolling.call(this, ...args)
  }

  pollSnapshot(...args) {
    return godViewLifecycleMethods.pollSnapshot.call(this, ...args)
  }

  decodeArrowGraph(...args) {
    return godViewLifecycleMethods.decodeArrowGraph.call(this, ...args)
  }
}
