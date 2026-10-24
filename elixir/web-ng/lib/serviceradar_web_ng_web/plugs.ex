defmodule ServiceRadarWebNGWeb.Plugs do
  @moduledoc false

  use Boundary,
    deps: [ServiceRadarWebNG, ServiceRadarWebNGWeb, ServiceRadarWebNGWeb.Auth],
    exports: :all
end
