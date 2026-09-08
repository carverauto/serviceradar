defmodule ServiceRadarWebNG.SRQLBehaviour do
  @moduledoc """
  Behaviour definition for SRQL query handlers.
  """

  @type srql_response :: map()

  @callback query(binary(), map()) :: {:ok, srql_response} | {:error, term()}
  @callback query_request(map()) :: {:ok, srql_response} | {:error, term()}
  @callback query_arrow(binary(), map()) :: {:ok, binary() | map()} | {:error, term()}

  @optional_callbacks query: 2, query_arrow: 2
end
