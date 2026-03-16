defmodule ServiceRadarWebNGWeb.Authorization do
  @moduledoc false

  use Permit, permissions_module: ServiceRadarWebNGWeb.Authorization.Permissions
end
