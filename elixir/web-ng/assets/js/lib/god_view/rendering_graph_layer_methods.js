import {godViewRenderingGraphLayerTransportMethods} from "./rendering_graph_layer_transport_methods"
import {godViewRenderingGraphLayerNodeMethods} from "./rendering_graph_layer_node_methods"
import {godViewRenderingHorizonEgressMethods} from "./rendering_horizon_egress_methods"

const godViewRenderingGraphLayerCoreMethods = {
  buildGraphLayers(effective, nodeData, edgeData, edgeLabelData, rootPulseNodes, nodeFrame = null) {
    const {
      baseLayers,
      mantleLayers,
      crustLayers,
      atmosphereLayers,
      securityLayers,
      mtrPathLayers,
    } = this.buildTransportAndEffectLayers(effective, nodeData, edgeData, rootPulseNodes)
    const horizonEgressLayers =
      typeof this.buildHorizonEgressLayers === "function"
        ? this.buildHorizonEgressLayers(nodeData)
        : []

    return [
      ...baseLayers,
      ...mantleLayers,
      ...crustLayers,
      ...(mtrPathLayers || []),
      ...this.buildNodeAndLabelLayers(effective, nodeData, edgeLabelData, nodeFrame),
      ...horizonEgressLayers,
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
  godViewRenderingHorizonEgressMethods,
)
