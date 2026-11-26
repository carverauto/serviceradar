defmodule ServiceRadarWebNGWeb.Api do
  @moduledoc false

  use Boundary,
    deps: [ServiceRadarWebNG.Catalog, ServiceRadarWebNGWeb, ServiceRadarWebNGWeb.Channels],
    exports: :all
end
