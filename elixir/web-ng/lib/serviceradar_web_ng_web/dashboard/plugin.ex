defmodule ServiceRadarWebNGWeb.Dashboard.Plugin do
  @moduledoc false

  @type srql_response :: map()

  @callback id() :: String.t()
  @callback title() :: String.t()
  @callback supports?(srql_response()) :: boolean()
  @callback build(srql_response()) :: {:ok, map()} | {:error, term()}
end
