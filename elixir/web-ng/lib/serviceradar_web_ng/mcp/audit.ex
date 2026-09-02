defmodule ServiceRadarWebNG.Mcp.Audit do
  @moduledoc """
  Non-blocking MCP audit events on the SecurityEvent stream.
  """

  alias ServiceRadar.Security.Events

  @spec auth_failed(keyword()) :: :ok
  def auth_failed(opts) do
    record(:mcp_auth_failed, :warning, opts)
  end

  @spec session_initialized(keyword()) :: :ok
  def session_initialized(opts) do
    record(:mcp_session_initialized, :info, opts)
  end

  @spec tool_called(keyword()) :: :ok
  def tool_called(opts) do
    record(:mcp_tool_called, :info, opts)
  end

  @spec tool_denied(keyword()) :: :ok
  def tool_denied(opts) do
    record(:mcp_tool_denied, :warning, opts)
  end

  @spec argument_digest(map()) :: String.t()
  def argument_digest(args) when is_map(args) do
    args
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  def argument_digest(_), do: nil

  defp record(kind, severity, opts) do
    Events.record(%{
      kind: kind,
      severity: severity,
      actor_id: stringify(Keyword.get(opts, :actor_id)),
      ip: Keyword.get(opts, :ip),
      route: Keyword.get(opts, :route, "/mcp"),
      details: details(opts)
    })
  end

  defp details(opts) do
    %{
      "tool" => Keyword.get(opts, :tool) && to_string(Keyword.get(opts, :tool)),
      "status" => Keyword.get(opts, :status) && to_string(Keyword.get(opts, :status)),
      "row_count" => Keyword.get(opts, :row_count),
      "duration_ms" => Keyword.get(opts, :duration_ms),
      "argument_digest" => Keyword.get(opts, :argument_digest),
      "query" => Keyword.get(opts, :query),
      "oauth_client_id" => stringify(Keyword.get(opts, :oauth_client_id)),
      "error" => Keyword.get(opts, :error)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
  end

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)
end
