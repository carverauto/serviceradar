defmodule ServiceRadarWebNG.Collectors do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ServiceRadarWebNG],
    exports: :all
end
