import {godViewRenderingStyleNodeMethods} from "./rendering_style_node_methods"
import {godViewRenderingStyleEdgeMethods} from "./rendering_style_edge_methods"
import {godViewRenderingStylePipelineMethods} from "./rendering_style_pipeline_methods"

export const godViewRenderingStyleMethods = Object.assign(
  {},
  godViewRenderingStyleNodeMethods,
  godViewRenderingStyleEdgeMethods,
  godViewRenderingStylePipelineMethods,
)
