/**
 * Adopts a resized canvas into Deck's own viewport before anything reads it back.
 *
 * Deck caches the canvas size that every viewport it hands out is built from, and refreshes
 * that cache only from its own animation frame. `setProps({width, height})` rewrites the
 * canvas CSS and then re-sends the PREVIOUS cached size to the view manager, so between a
 * resize and the next frame `deck.getViewports()` -- and the frame `redraw(true)` draws --
 * still describe the old viewport. Everything downstream of a resize projects through that
 * viewport: the label admission that decides which labels fit, the layer refresh, and the
 * acceptance geometry observer. Comparing projections taken in the old frame against the safe
 * rect measured in the new one is how a scene that fits exactly reports glyphs 560px outside
 * it -- half the width difference between the two frames.
 *
 * Deck's refresh is idempotent, so pulling it forward costs nothing and leaves no frame drawn
 * at the wrong size. Since deck.gl 9.4 it reads the size from luma's canvas context, which
 * learns it from a ResizeObserver one frame later -- so the context is told the new CSS size
 * first. It is internal API, so a Deck that no longer exposes it degrades to the old behaviour
 * (one stale frame) rather than failing: the fallback still corrects the view manager, even
 * though Deck's next `setProps` re-asserts its own cached size over it.
 */
export function adoptDeckViewportSize(deck, width, height) {
  syncCanvasContextSize(deck?.device?.canvasContext, width, height)
  if (typeof deck?._updateCanvasSize === "function") {
    deck._updateCanvasSize()
    if (Number(deck.width) === width && Number(deck.height) === height) return true
  }
  if (typeof deck?.viewManager?.setProps === "function") {
    deck.viewManager.setProps({width, height})
    return true
  }
  return false
}

/**
 * Applies a new CSS size to luma's canvas context the way its ResizeObserver callback would:
 * CSS size, device-pixel size and drawing buffer together. Moving the CSS size alone leaves a
 * drawing buffer at the old size, and deck then derives a viewport larger than the buffer --
 * which WebGPU rejects ("Viewport bounds ... contains a negative value") where WebGL clipped.
 */
export function syncCanvasContextSize(canvasContext, width, height) {
  if (!canvasContext || typeof canvasContext.getCSSSize !== "function" || !("cssWidth" in canvasContext)) return
  canvasContext.cssWidth = width
  canvasContext.cssHeight = height
  if (
    typeof canvasContext._getDevicePixelSizeFromCSSSize === "function" &&
    typeof canvasContext._setDevicePixelSize === "function" &&
    typeof canvasContext._updateDrawingBufferSize === "function"
  ) {
    canvasContext._setDevicePixelSize(canvasContext._getDevicePixelSizeFromCSSSize(width, height))
    canvasContext._updateDrawingBufferSize()
  }
}
