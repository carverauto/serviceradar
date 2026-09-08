defmodule ServiceRadarWebNG.Mcp.OAuth.IdPRefreshClient do
  @moduledoc false

  @callback refresh_tokens(String.t()) :: {:ok, map()} | {:error, term()}
end
