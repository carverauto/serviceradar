defmodule ServiceRadarWebNG.SRQLBehaviour do
  @moduledoc false

  @type srql_response :: map()

  @callback query_request(map()) :: {:ok, srql_response} | {:error, term()}
end
