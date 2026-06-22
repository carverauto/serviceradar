defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.AsnLookup.Cache do
  @moduledoc false

  @table :netflow_arin_asn_cache
  @ttl_ms 6 * 60 * 60 * 1000
  @negative_ttl_ms 60 * 1000

  def get(asn) when is_integer(asn) do
    ensure_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, asn) do
      [{^asn, expires_at_ms, result}] when is_integer(expires_at_ms) and expires_at_ms > now ->
        {:hit, result}

      [{^asn, _expires_at_ms, _result}] ->
        _ = :ets.delete(@table, asn)
        :miss

      _ ->
        :miss
    end
  rescue
    _ -> :miss
  end

  def put(asn, result) when is_integer(asn) do
    ensure_table()
    ttl_ms = if match?({:ok, _}, result), do: @ttl_ms, else: @negative_ttl_ms
    expires_at_ms = System.monotonic_time(:millisecond) + ttl_ms
    _ = :ets.insert(@table, {asn, expires_at_ms, result})
    :ok
  rescue
    _ -> :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> create_table()
      _ -> :ok
    end
  end

  defp create_table do
    :ets.new(@table, [
      :named_table,
      :set,
      :public,
      {:read_concurrency, true},
      {:write_concurrency, true}
    ])

    :ok
  rescue
    ArgumentError -> :ok
  end
end
