defmodule ServiceRadarWebNG.Edge.Workers do
  @moduledoc false

  use Boundary,
    deps: [ServiceRadarWebNG, ServiceRadarWebNG.Edge],
    exports: :all
end
