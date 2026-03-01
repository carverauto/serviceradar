import {godViewRenderingTooltipMethods} from "./rendering_tooltip_methods"
import {godViewRenderingSelectionMethods} from "./rendering_selection_methods"
import {godViewRenderingGraphMethods} from "./rendering_graph_methods"
import {godViewRenderingStyleMethods} from "./rendering_style_methods"

export const godViewRenderingMethods = Object.assign(
  {},
  godViewRenderingTooltipMethods,
  godViewRenderingSelectionMethods,
  godViewRenderingGraphMethods,
  godViewRenderingStyleMethods,
)
