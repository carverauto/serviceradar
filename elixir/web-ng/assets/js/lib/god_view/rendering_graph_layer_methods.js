import {godViewRenderingGraphLayerTransportMethods} from "./rendering_graph_layer_transport_methods"
import {godViewRenderingGraphLayerNodeMethods} from "./rendering_graph_layer_node_methods"

const godViewRenderingGraphLayerCoreMethods = {
  buildGraphLayers(effective, nodeData, edgeData, edgeLabelData, rootPulseNodes) {
    const {
      baseLayers,
      mantleLayers,
      crustLayers,
      atmosphereLayers,
      securityLayers,
    } = this.buildTransportAndEffectLayers(effective, nodeData, edgeData, rootPulseNodes)

    return [
      ...baseLayers,
      ...mantleLayers,
      ...crustLayers,
      ...this.buildNodeAndLabelLayers(effective, nodeData, edgeLabelData),
      ...securityLayers,
      ...atmosphereLayers,
    ]
  },
}

export const godViewRenderingGraphLayerMethods = Object.assign(
  {},
  godViewRenderingGraphLayerCoreMethods,
  godViewRenderingGraphLayerTransportMethods,
  godViewRenderingGraphLayerNodeMethods,
)
