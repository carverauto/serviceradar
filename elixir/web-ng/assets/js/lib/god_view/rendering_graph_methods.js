import {godViewRenderingGraphBitmapMethods} from "./rendering_graph_bitmap_methods"
import {godViewRenderingGraphCoreMethods} from "./rendering_graph_core_methods"
import {godViewRenderingGraphDataMethods} from "./rendering_graph_data_methods"
import {godViewRenderingGraphLayerMethods} from "./rendering_graph_layer_methods"
import {godViewRenderingGraphViewMethods} from "./rendering_graph_view_methods"

export const godViewRenderingGraphMethods = Object.assign(
  {},
  godViewRenderingGraphCoreMethods,
  godViewRenderingGraphDataMethods,
  godViewRenderingGraphLayerMethods,
  godViewRenderingGraphBitmapMethods,
  godViewRenderingGraphViewMethods,
)
