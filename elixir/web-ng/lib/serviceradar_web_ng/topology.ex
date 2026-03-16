defmodule ServiceRadarWebNG.Topology do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ServiceRadarWebNG, ServiceRadarWebNG.Graph],
    exports: :all
end
