defmodule ServiceRadarWebNGWeb.NetFlow.EnrichmentExpiry do
  @moduledoc false

  import Ash.Expr

  require Ash.Query

  def live(query, %DateTime{} = now) do
    Ash.Query.filter(query, expr(is_nil(expires_at) or expires_at > ^now))
  end

  def live_for_ips(query, ips, %DateTime{} = now) when is_list(ips) do
    Ash.Query.filter(query, expr(ip in ^ips and (is_nil(expires_at) or expires_at > ^now)))
  end

  def sql(alias_name) when is_binary(alias_name) do
    "(#{alias_name}.expires_at IS NULL OR #{alias_name}.expires_at > now())"
  end
end
