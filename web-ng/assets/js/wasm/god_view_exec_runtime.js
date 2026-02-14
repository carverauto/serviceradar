import wasmUrl from "./god_view_exec.wasm"

export class GodViewWasmEngine {
  constructor(instance) {
    this.instance = instance
    this.exports = instance.exports
    this.memory = this.exports.memory
  }

  static async init() {
    const response = await fetch(wasmUrl)
    let result

    if (WebAssembly.instantiateStreaming) {
      try {
        result = await WebAssembly.instantiateStreaming(response, {})
      } catch (_err) {
        const bytes = await (await fetch(wasmUrl)).arrayBuffer()
        result = await WebAssembly.instantiate(bytes, {})
      }
    } else {
      const bytes = await response.arrayBuffer()
      result = await WebAssembly.instantiate(bytes, {})
    }

    return new GodViewWasmEngine(result.instance)
  }

  computeStateMask(states, filters) {
    const len = states.length
    const statesPtr = this.exports.alloc_bytes(len)
    const maskPtr = this.exports.alloc_bytes(len)

    try {
      this.writeBytes(statesPtr, states)
      this.exports.compute_state_mask(
        statesPtr,
        len,
        filters.root_cause ? 1 : 0,
        filters.affected ? 1 : 0,
        filters.healthy ? 1 : 0,
        filters.unknown ? 1 : 0,
        maskPtr,
      )
      return new Uint8Array(this.memory.buffer, maskPtr, len).slice()
    } finally {
      this.exports.free_bytes(statesPtr, len)
      this.exports.free_bytes(maskPtr, len)
    }
  }

  computeThreeHopMask(nodeCount, edgeSource, edgeTarget, startNode) {
    if (nodeCount <= 0) return new Uint8Array(0)
    if (startNode < 0 || startNode >= nodeCount) return new Uint8Array(nodeCount)
    if (edgeSource.length === 0) {
      const mask = new Uint8Array(nodeCount)
      mask[startNode] = 1
      return mask
    }

    const edgeBytes = edgeSource.byteLength
    const srcPtr = this.exports.alloc_bytes(edgeBytes)
    const dstPtr = this.exports.alloc_bytes(edgeBytes)
    const maskPtr = this.exports.alloc_bytes(nodeCount)

    try {
      this.writeBytes(srcPtr, new Uint8Array(edgeSource.buffer, edgeSource.byteOffset, edgeBytes))
      this.writeBytes(dstPtr, new Uint8Array(edgeTarget.buffer, edgeTarget.byteOffset, edgeBytes))
      this.exports.compute_three_hop_mask(
        nodeCount,
        srcPtr,
        dstPtr,
        edgeSource.length,
        startNode,
        maskPtr,
      )
      return new Uint8Array(this.memory.buffer, maskPtr, nodeCount).slice()
    } finally {
      this.exports.free_bytes(srcPtr, edgeBytes)
      this.exports.free_bytes(dstPtr, edgeBytes)
      this.exports.free_bytes(maskPtr, nodeCount)
    }
  }

  computeInterpolatedXY(previousXY, nextXY, t) {
    const byteLength = previousXY.byteLength
    const prevPtr = this.exports.alloc_bytes(byteLength)
    const nextPtr = this.exports.alloc_bytes(byteLength)
    const outPtr = this.exports.alloc_bytes(byteLength)

    try {
      this.writeBytes(prevPtr, new Uint8Array(previousXY.buffer, previousXY.byteOffset, byteLength))
      this.writeBytes(nextPtr, new Uint8Array(nextXY.buffer, nextXY.byteOffset, byteLength))
      this.exports.compute_interpolated_xy(prevPtr, nextPtr, previousXY.length, t, outPtr)
      const outBytes = new Uint8Array(this.memory.buffer, outPtr, byteLength).slice()
      return new Float32Array(outBytes.buffer, outBytes.byteOffset, previousXY.length)
    } finally {
      this.exports.free_bytes(prevPtr, byteLength)
      this.exports.free_bytes(nextPtr, byteLength)
      this.exports.free_bytes(outPtr, byteLength)
    }
  }

  writeBytes(ptr, bytes) {
    const view = new Uint8Array(this.memory.buffer, ptr, bytes.length)
    view.set(bytes)
  }
}
