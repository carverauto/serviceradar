# deck.gl 9.4 WebGPU picking

`deck.gl-core-9.4.0.patch` corrects the coordinate boundary in asynchronous
picking. deck.gl computes picking rectangles in bottom-left coordinates, while
WebGPU scissors and texture copies use top-left coordinates. Convert the GPU
rectangle and reverse readback rows so the existing closest-pixel decoder keeps
its coordinate convention. CSS culling rectangles and WebGL are unchanged.

The patch covers the published ESM and CommonJS modules and their TypeScript
source. Both pnpm and Bazel apply the same patch. Remove it when an upstream
release fixes this boundary and passes the real GPU checks.

Reproduced on Chrome with Apple Metal WebGPU: a node at canvas y=129 could only
be picked at y=491 in a 620-pixel canvas. The RBE-built `world_gpu_smoke` target
now supports node clicks, edge picks and rectangle picks at the visible
coordinates with packet flow enabled. Empty-space picks remain empty.
