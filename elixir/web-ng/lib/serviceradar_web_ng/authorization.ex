defmodule ServiceRadarWebNG.Authorization do
  @moduledoc false

  use Permit, permissions_module: ServiceRadarWebNG.Authorization.Permissions
end
