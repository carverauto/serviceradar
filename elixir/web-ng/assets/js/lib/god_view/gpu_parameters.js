/**
 * Render-pipeline parameters for God View layers, in luma.gl's device-neutral vocabulary.
 *
 * God View renders on WebGPU only. There, deck.gl's layer shaders emit premultiplied alpha and
 * its default draw parameters blend `one, one-minus-src-alpha` with a depth test. God View is a
 * flat overlay, so layers switch the depth test off and pick one of two blends. The WebGL-era
 * `depthTest` / `blendFunc: [GL enums]` form has no meaning on a WebGPU device.
 */

/** No depth test and no depth writes: later layers always draw over earlier ones. */
export const GOD_VIEW_NO_DEPTH = Object.freeze({
  depthWriteEnabled: false,
  depthCompare: "always",
})

/** Standard "over" compositing for premultiplied colors. */
export const GOD_VIEW_ALPHA_BLEND = Object.freeze({
  ...GOD_VIEW_NO_DEPTH,
  blend: true,
  blendColorOperation: "add",
  blendColorSrcFactor: "one",
  blendColorDstFactor: "one-minus-src-alpha",
  blendAlphaOperation: "add",
  blendAlphaSrcFactor: "one",
  blendAlphaDstFactor: "one-minus-src-alpha",
})

/** Additive glow for premultiplied colors: each particle brightens what is under it. */
export const GOD_VIEW_ADDITIVE_BLEND = Object.freeze({
  ...GOD_VIEW_NO_DEPTH,
  blend: true,
  blendColorOperation: "add",
  blendColorSrcFactor: "one",
  blendColorDstFactor: "one",
  blendAlphaOperation: "add",
  blendAlphaSrcFactor: "one",
  blendAlphaDstFactor: "one",
})
