defmodule ServiceRadarWebNG.Dev do
  @moduledoc false

  use Boundary,
    deps: [ServiceRadarWebNG],
    exports: :all
end
