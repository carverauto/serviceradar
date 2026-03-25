defmodule ServiceRadarCoreElx do
  @moduledoc """
  Root Boundary for the core runtime application.
  """

  use Boundary,
    check: [apps: [:serviceradar_core]],
    deps: [ServiceRadar],
    exports: :all
end
