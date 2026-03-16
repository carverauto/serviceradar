defmodule ServiceRadarWebNG.Auth do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ServiceRadar],
    exports: :all
end
