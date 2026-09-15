defmodule ServiceRadar.AnalyticsStore.Pruner do
  @moduledoc """
  Drop published Parquet objects older than a table's configured window.

  Pure pg_duckdb uses `Registry.hot_retention_days/1`, driven by
  `SERVICERADAR_*_RETENTION_DAYS`. Hybrid uses its separate
  `parquet_retention_days`; an unset archive window never deletes files.
  Objects are deleted first;
  manifest rows follow so a reader never sees a live key whose object is
  gone. Staging keys are never globbed by readers, but expired staging
  objects are deleted too.

  Dual-write and timescale-only deployments are a no-op: nothing has
  flipped, so Timescale retention still owns the data.
  """

  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.AnalyticsStore.FileManifest
  alias ServiceRadar.AnalyticsStore.Storage
  alias ServiceRadar.ColdTier.ObjectStore
  alias ServiceRadar.ColdTier.Registry

  require Logger

  @doc "UTC cutoff date (exclusive) for `entry`'s retention window."
  @spec cutoff_date(Registry.Table.t(), DateTime.t()) :: Date.t()
  def cutoff_date(%Registry.Table{} = entry, %DateTime{} = now) do
    days = Registry.hot_retention_days(entry)
    now |> DateTime.to_date() |> Date.add(-days)
  end

  @doc "Archive cutoff for a table, or nil when hybrid archive expiry is not configured."
  @spec cutoff_date(Registry.Table.t(), DateTime.t(), Config.t()) :: Date.t() | nil
  def cutoff_date(%Registry.Table{} = entry, %DateTime{} = now, %Config{} = cfg) do
    case {Config.driver_for(cfg, entry.table), cfg.parquet_retention_days} do
      {:hybrid, nil} -> nil
      {:hybrid, days} -> now |> DateTime.to_date() |> Date.add(-days)
      _ -> cutoff_date(entry, now)
    end
  end

  @doc """
  Delete expired published objects for every flipped table.

  Inject `:list_expired`, `:delete_objects`, and `:forget` in tests.
  Default reads `FileManifest` and deletes through the configured backend.
  """
  @spec prune_expired(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune_expired(opts \\ []) do
    cfg = Keyword.get_lazy(opts, :config, &Config.load/0)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    list = Keyword.get(opts, :list_expired, &default_list/2)
    delete = Keyword.get(opts, :delete_objects, &default_delete(&1, cfg))
    forget = Keyword.get(opts, :forget, &default_forget/1)

    result =
      Enum.reduce_while(
        Config.flipped_tables(cfg) ++ Config.hybrid_tables(cfg),
        {:ok, 0},
        fn entry, {:ok, acc} ->
          case cutoff_date(entry, now, cfg) do
            nil ->
              {:cont, {:ok, acc}}

            cutoff ->
              keys = list.(entry.table, cutoff)

              case delete.(keys) do
                {:ok, deleted} ->
                  Enum.each(keys, forget)
                  {:cont, {:ok, acc + deleted}}

                {:error, reason} ->
                  {:halt, {:error, reason}}
              end
          end
        end
      )

    case result do
      {:ok, 0} ->
        {:ok, 0}

      {:ok, n} ->
        Logger.info("analytics store: pruned expired parquet objects", deleted: n)
        {:ok, n}

      {:error, reason} = error ->
        Logger.warning("analytics store: parquet prune failed", reason: inspect(reason))
        error
    end
  end

  defp default_list(table, %Date{} = cutoff) do
    FileManifest.expired_keys(table, cutoff)
  end

  defp default_delete([], _cfg), do: {:ok, 0}

  defp default_delete(keys, %Config{storage: :filesystem, filesystem_path: path})
       when is_binary(path) and path != "" do
    Enum.reduce_while(keys, {:ok, 0}, fn key, {:ok, acc} ->
      case Storage.copy_target(%Config{storage: :filesystem, filesystem_path: path}, key) do
        {:ok, full} ->
          case File.rm(full) do
            :ok -> {:cont, {:ok, acc + 1}}
            {:error, :enoent} -> {:cont, {:ok, acc + 1}}
            {:error, reason} -> {:halt, {:error, {:filesystem_delete, key, reason}}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp default_delete(keys, cfg) do
    case Config.s3_secret(cfg) do
      {:ok, s3} -> ObjectStore.delete_objects(keys, s3_context(s3))
      :disabled -> {:error, :storage_unavailable}
    end
  end

  defp default_forget(key), do: FileManifest.forget(key)

  defp s3_context(s3) do
    bucket = s3.bucket_url |> String.replace_prefix("s3://", "") |> String.trim_trailing("/")
    scheme = if s3.use_ssl == false, do: "http", else: "https"

    endpoint =
      s3.endpoint
      |> to_string()
      |> String.replace_prefix("https://", "")
      |> String.replace_prefix("http://", "")

    %{
      base_url: "#{scheme}://#{endpoint}/#{bucket}",
      access_key_id: s3.access_key_id,
      secret_access_key: s3.secret_access_key,
      region: s3.region
    }
  end
end
