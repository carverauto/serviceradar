import {godViewRenderingStyleEdgeParticleMethods} from "./rendering_style_edge_particle_methods"
import {godViewRenderingStyleEdgeTelemetryMethods} from "./rendering_style_edge_telemetry_methods"
import {godViewRenderingStyleEdgeTopologyMethods} from "./rendering_style_edge_topology_methods"

export const godViewRenderingStyleEdgeMethods = Object.assign(
  {},
  godViewRenderingStyleEdgeTelemetryMethods,
  godViewRenderingStyleEdgeTopologyMethods,
  godViewRenderingStyleEdgeParticleMethods,
)
