defmodule ServiceRadarWebNG.Mcp.OAuth.Audit do
  @moduledoc false

  alias ServiceRadar.Security.Events

  def authorize_approved(opts), do: record(:mcp_oauth_authorize_approved, :info, opts)
  def authorize_denied(opts), do: record(:mcp_oauth_authorize_denied, :warning, opts)
  def token_issued(opts), do: record(:mcp_oauth_token_issued, :info, opts)
  def refreshed(opts), do: record(:mcp_oauth_refreshed, :info, opts)
  def refresh_reuse(opts), do: record(:mcp_oauth_refresh_reuse, :warning, opts)
  def grant_revoked(opts), do: record(:mcp_oauth_grant_revoked, :info, opts)
  def idp_refresh_denied(opts), do: record(:mcp_oauth_idp_refresh_denied, :warning, opts)
  def slo_revoked(opts), do: record(:mcp_oauth_slo_revoked, :warning, opts)

  defp record(kind, severity, opts) do
    Events.record(%{
      kind: kind,
      severity: severity,
      actor_id: stringify(Keyword.get(opts, :actor_id)),
      ip: Keyword.get(opts, :ip),
      route: Keyword.get(opts, :route, "/oauth/token"),
      details:
        %{
          "client_id" => Keyword.get(opts, :client_id),
          "scope" => Keyword.get(opts, :scope),
          "idp_sid" => Keyword.get(opts, :idp_sid),
          "error" => Keyword.get(opts, :error)
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
        |> Map.new()
    })
  end

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)
end
