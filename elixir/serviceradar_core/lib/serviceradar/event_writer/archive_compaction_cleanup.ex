defmodule ServiceRadar.EventWriter.ArchiveCompactionCleanup do
  @moduledoc """
  Retire expired manifest entries and reclaim superseded or expired S3 objects after the manifest reader grace period.

  Deletion never changes query-visible membership. Each retired file is marked
  cleaned only after both its object and staging key return HEAD 404; failed
  or partial requests leave retryable catalog records. Source membership stays
  recorded for archive publication provenance.
  """

  use Oban.Worker,
    queue: :maintenance,
    priority: 3,
    max_attempts: 5,
    unique: [period: 60, states: :incomplete]

  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.AnalyticsStore.FileManifest
  alias ServiceRadar.AnalyticsStore.ManifestCompaction
  alias ServiceRadar.AnalyticsStore.Pruner
  alias ServiceRadar.ColdTier.ObjectStore

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: run(Config.load())

  @doc "Clean a bounded group per enabled hybrid table; no head connection is required."
  def run(cfg, opts \\ [])

  def run(%Config{driver: :hybrid, storage: :s3} = cfg, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    prune = Keyword.get(opts, :prune, &Pruner.prune_expired/1)

    with {:ok, _retired} <- prune.(config: cfg, now: now),
         {:ok, s3} <- Config.s3_secret(cfg) do
      ctx = s3_context(s3)
      before = DateTime.add(now, -ManifestCompaction.reader_grace_seconds(), :second)
      list = Keyword.get(opts, :list, &FileManifest.retired_files/3)
      delete = Keyword.get(opts, :delete, &ObjectStore.delete_objects(&1, ctx))
      absent = Keyword.get(opts, :absent?, &ObjectStore.object_absent?(&1, ctx))
      mark = Keyword.get(opts, :mark, &FileManifest.mark_objects_deleted(&1, now: now))

      Enum.reduce_while(Config.hybrid_tables(cfg), {:ok, 0}, fn entry, {:ok, total} ->
        with {:ok, files} <- list.(entry.table, before, 32),
             {:ok, count} <- clean_files(files, delete, absent, mark) do
          {:cont, {:ok, total + count}}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  # Filesystem objects belong to the head's mount, which is not necessarily
  # visible to the application. Do not infer remote absence from a local path.
  def run(%Config{}, _opts), do: {:ok, 0}

  defp clean_files(files, delete, absent, mark) do
    Enum.reduce_while(files, {:ok, 0}, fn file, {:ok, count} ->
      keys = Enum.uniq([file.object_key, file.staging_key])

      with {:ok, _deleted} <- delete.(keys),
           :ok <- verify_absent(keys, absent),
           :ok <- mark.(file.id) do
        {:cont, {:ok, count + 1}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp verify_absent(keys, absent) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case absent.(key) do
        {:ok, true} -> {:cont, :ok}
        {:ok, false} -> {:halt, {:error, :retired_object_still_present}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp s3_context(s3) do
    bucket = s3.bucket_url |> String.replace_prefix("s3://", "") |> String.trim_trailing("/")
    scheme = if s3.use_ssl == false, do: "http", else: "https"

    endpoint =
      s3.endpoint |> String.replace_prefix("https://", "") |> String.replace_prefix("http://", "")

    %{
      base_url: "#{scheme}://#{endpoint}/#{bucket}",
      access_key_id: s3.access_key_id,
      secret_access_key: s3.secret_access_key,
      region: s3.region
    }
  end
end
