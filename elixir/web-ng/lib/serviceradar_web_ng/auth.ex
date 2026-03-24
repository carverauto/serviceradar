defmodule ServiceRadarWebNG.Auth do
  @moduledoc false

  use Boundary,
    top_level?: true,
    check: [apps: [:serviceradar_core]],
    deps: [ServiceRadar],
    exports: :all
end
