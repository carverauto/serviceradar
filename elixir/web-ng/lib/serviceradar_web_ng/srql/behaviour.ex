defmodule ServiceRadarWebNG.SRQLBehaviour do
  @moduledoc """
  Behaviour definition for SRQL query handlers.
  """

  @type srql_response :: map()

  @callback query_request(map()) :: {:ok, srql_response} | {:error, term()}
end
