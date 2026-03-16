defmodule ServiceRadarWebNG.Web do
  @moduledoc false

  use Boundary,
    deps: [ServiceRadarWebNG, ServiceRadarWebNGWeb],
    exports: :all
end
