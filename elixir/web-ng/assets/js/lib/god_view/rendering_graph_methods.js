import {godViewRenderingGraphBitmapMethods} from "./rendering_graph_bitmap_methods"
import {godViewRenderingGraphCoreMethods} from "./rendering_graph_core_methods"
import {godViewRenderingGraphViewMethods} from "./rendering_graph_view_methods"

export const godViewRenderingGraphMethods = Object.assign(
  {},
  godViewRenderingGraphCoreMethods,
  godViewRenderingGraphBitmapMethods,
  godViewRenderingGraphViewMethods,
)
