defmodule ServiceRadarWebNGWeb.AuthLive do
  @moduledoc false

  use Boundary,
    deps: [ServiceRadarWebNGWeb, ServiceRadarWebNGWeb.Auth],
    exports: :all
end
