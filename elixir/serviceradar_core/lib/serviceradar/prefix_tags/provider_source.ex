defmodule ServiceRadar.PrefixTags.ProviderSource do
  @moduledoc """
  Compiles the active cloud-provider CIDR snapshot into the `provider` trie.

  Preserves `netflow_provider_dataset_snapshots` / `netflow_provider_cidrs` as the
  import pipeline; this module only materializes the active snapshot into
  `ServiceRadar.PrefixTags.Store` under source `"provider"` with tags of the form
  `provider:<name>`.
  """

  @behaviour ServiceRadar.PrefixTags.ExternalSources

  alias Ecto.Adapters.SQL
  alias ServiceRadar.PrefixTags.ExternalSources
  alias ServiceRadar.PrefixTags.Loader
  alias ServiceRadar.PrefixTags.Store
  alias ServiceRadar.Repo

  require Logger

  @source "provider"

  @load_active_sql """
  SELECT
    s.id AS snapshot_id,
    COALESCE(s.promoted_at, s.fetched_at, s.inserted_at) AS snapshot_at,
    host(c.cidr) || '/' || masklen(c.cidr) AS prefix,
    c.provider
  FROM platform.netflow_provider_dataset_snapshots s
  LEFT JOIN platform.netflow_provider_cidrs c ON c.snapshot_id = s.id
  WHERE s.is_active = TRUE
  """

  @doc "Canonical Store source name for hosting-provider tags."
  @impl true
  @spec source_name() :: String.t()
  def source_name, do: @source

  @doc """
  Load the active provider snapshot into the prefix-tag Store.

  Options:
  - `:broadcast?` (default `true`) — notify peer nodes. Loaders that invoke
    this on invalidation must pass `broadcast?: false` to avoid a PubSub loop.
  """
  @impl true
  @spec reload(keyword()) ::
          {:ok, ExternalSources.reload_result()} | {:error, term()}
  def reload(opts \\ []) do
    broadcast? = Keyword.get(opts, :broadcast?, true)

    case SQL.query(Repo, @load_active_sql, []) do
      {:ok, result} ->
        %{active_snapshot?: active_snapshot?, rows: rows, snapshot_at: snapshot_at} =
          parse_query_result(result)

        if active_snapshot? do
          # An active, authoritative zero-row snapshot must remain registered
          # as loaded so callers do not fall back to an older SQL cache.
          _ = Store.put_rows(@source, rows)
        else
          Store.clear(@source)
        end

        maybe_broadcast(broadcast?)
        Logger.info("PrefixTags.ProviderSource loaded provider trie", rows: length(rows))
        {:ok, ExternalSources.reload_result(length(rows), snapshot_at)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp maybe_broadcast(true), do: Loader.broadcast_invalidation(%{source: @source})
  defp maybe_broadcast(false), do: :ok

  @doc "Resolve hosting provider name for an IP from the provider trie only."
  @spec provider_for_ip(String.t() | nil) :: String.t() | nil
  def provider_for_ip(nil), do: nil

  def provider_for_ip(ip) when is_binary(ip) do
    case Store.lookup(ip, @source) do
      [%{tags: tags} | _] ->
        Enum.find_value(tags, fn
          "provider:" <> name when name != "" -> name
          _ -> nil
        end)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  @doc false
  @spec parse_query_result(map()) :: %{
          active_snapshot?: boolean(),
          rows: [map()],
          snapshot_at: DateTime.t() | nil
        }
  def parse_query_result(%{rows: rows}) when is_list(rows) do
    active_snapshot? =
      Enum.any?(rows, fn
        [snapshot_id, _snapshot_at, _prefix, _provider] -> not is_nil(snapshot_id)
        _ -> false
      end)

    snapshot_at =
      Enum.find_value(rows, fn
        [_snapshot_id, value, _prefix, _provider] ->
          ExternalSources.normalize_datetime(value)

        _ ->
          nil
      end)

    parsed =
      Enum.flat_map(rows, fn
        [_snapshot_id, _snapshot_at, prefix, provider]
        when is_binary(prefix) and is_binary(provider) and provider != "" ->
          [
            %{
              prefix: prefix,
              tags: ["provider:#{provider}"],
              source: @source
            }
          ]

        _ ->
          []
      end)

    %{active_snapshot?: active_snapshot?, rows: parsed, snapshot_at: snapshot_at}
  end
end
