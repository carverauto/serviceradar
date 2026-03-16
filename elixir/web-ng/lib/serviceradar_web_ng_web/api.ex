defmodule ServiceRadarWebNGWeb.Api do
  @moduledoc false

  use Boundary,
    deps: [ServiceRadarWebNGWeb, ServiceRadarWebNGWeb.Channels],
    exports: :all
end
