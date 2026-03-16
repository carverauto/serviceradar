defmodule ServiceRadarCoreElx do
  @moduledoc """
  Root Boundary for the core runtime application.
  """

  use Boundary,
    deps: [ServiceRadar],
    exports: :all
end
