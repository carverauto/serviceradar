import {godViewRenderingStyleNodeReasonMethods} from "./rendering_style_node_reason_methods"
import {godViewRenderingStyleNodeVisualMethods} from "./rendering_style_node_visual_methods"

export const godViewRenderingStyleNodeMethods = Object.assign(
  {},
  godViewRenderingStyleNodeReasonMethods,
  godViewRenderingStyleNodeVisualMethods,
)
