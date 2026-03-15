defmodule ServiceRadarWebNG.Topology do
  @moduledoc false

  use Boundary,
    deps: [ServiceRadarWebNG, ServiceRadarWebNG.Graph],
    exports: :all
end
