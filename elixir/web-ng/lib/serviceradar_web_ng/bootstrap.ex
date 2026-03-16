defmodule ServiceRadarWebNG.Bootstrap do
  @moduledoc false

  use Boundary,
    deps: [ServiceRadarWebNG],
    exports: :all
end
