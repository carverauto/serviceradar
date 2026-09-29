defmodule ServiceRadarWebNG.Topology do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ServiceRadarWebNG, ServiceRadarWebNG.Graph, ServiceRadarWebNG.RBAC],
    exports: :all
end
