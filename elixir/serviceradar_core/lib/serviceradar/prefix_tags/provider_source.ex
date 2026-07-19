defmodule ServiceRadar.PrefixTags.ProviderSource do
  @moduledoc """
  Compiles the active cloud-provider CIDR snapshot into the `provider` trie.

  Preserves `netflow_provider_dataset_snapshots` / `netflow_provider_cidrs` as the
  import pipeline; this module only materializes the active snapshot into
  `ServiceRadar.PrefixTags.Store` under source `"provider"` with tags of the form
  `provider:<name>`.
  """

  alias Ecto.Adapters.SQL
  alias ServiceRadar.PrefixTags.Loader
  alias ServiceRadar.PrefixTags.Store
  alias ServiceRadar.Repo

  require Logger

  @source "provider"

  @active_snapshot_sql """
  SELECT id
  FROM platform.netflow_provider_dataset_snapshots
  WHERE is_active = TRUE
  LIMIT 1
  """

  @load_cidrs_sql """
  SELECT host(c.cidr) || '/' || masklen(c.cidr) AS prefix, c.provider
  FROM platform.netflow_provider_cidrs c
  WHERE c.snapshot_id = $1
  """

  @doc "Canonical Store source name for hosting-provider tags."
  @spec source_name() :: String.t()
  def source_name, do: @source

  @doc """
  Load the active provider snapshot into the prefix-tag Store.

  Options:
  - `:broadcast?` (default `true`) — notify peer nodes. Loaders that invoke
    this on invalidation must pass `broadcast?: false` to avoid a PubSub loop.
  """
  @spec reload(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def reload(opts \\ []) do
    broadcast? = Keyword.get(opts, :broadcast?, true)

    case fetch_active_snapshot_id() do
      {:ok, nil} ->
        Store.clear(@source)
        maybe_broadcast(broadcast?)
        {:ok, 0}

      {:ok, snapshot_id} ->
        case fetch_rows(snapshot_id) do
          {:ok, rows} ->
            _ = Store.put_rows(@source, rows)
            maybe_broadcast(broadcast?)
            Logger.info("PrefixTags.ProviderSource loaded provider trie", rows: length(rows))
            {:ok, length(rows)}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
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

  defp fetch_active_snapshot_id do
    case SQL.query(Repo, @active_snapshot_sql, []) do
      {:ok, %{rows: [[id]]}} -> {:ok, id}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp fetch_rows(snapshot_id) do
    case SQL.query(Repo, @load_cidrs_sql, [snapshot_id]) do
      {:ok, %{rows: rows}} ->
        parsed =
          rows
          |> Enum.map(fn [prefix, provider] ->
            if is_binary(prefix) and is_binary(provider) and provider != "" do
              %{
                prefix: prefix,
                tags: ["provider:#{provider}"],
                source: @source
              }
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, parsed}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end
end
