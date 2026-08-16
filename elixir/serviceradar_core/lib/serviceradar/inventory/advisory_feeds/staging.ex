defmodule ServiceRadar.Inventory.AdvisoryFeeds.Staging do
  @moduledoc """
  On-disk staging for advisory feed downloads (design D2).

  Layout, rooted at `SERVICERADAR_ADVISORY_STAGING_DIR`
  (default `/var/lib/serviceradar/advisory-feeds`):

      <root>/<feed_key>/<run_id>/
        download.zip            # streamed from the presigned URL to disk
        extracted/              # unzip output (json, or *.json.gz shards)

  The staging volume MUST be a real mounted volume; when it is absent the large
  nist-nvd2 feed fails closed (never an in-memory fallback). Per-run dirs are
  removed on success; orphans older than the retention window are reaped on
  startup.
  """

  require Logger

  @default_root "/var/lib/serviceradar/advisory-feeds"
  # Keep a killed nist-nvd2 extract long enough for a later core to resume
  # the same shards instead of re-downloading. Daily cadence + a couple of
  # failed rolls still fits; older dirs are reaped on the next scheduler tick.
  @orphan_max_age_seconds 36 * 60 * 60

  @doc "Staging root directory (env-overridable)."
  @spec root() :: Path.t()
  def root do
    System.get_env("SERVICERADAR_ADVISORY_STAGING_DIR") ||
      Application.get_env(:serviceradar_core, :advisory_staging_dir, @default_root)
  end

  @doc """
  Is the staging volume usable (exists and writable)?

  Used by feed workers to fail closed for large feeds when the PVC/volume is not
  mounted.
  """
  @spec volume_available?() :: boolean()
  def volume_available?(dir \\ root()) do
    with :ok <- ensure_dir(dir),
         probe = Path.join(dir, ".write-probe-#{System.unique_integer([:positive])}"),
         :ok <- File.write(probe, "ok") do
      _ = File.rm(probe)
      true
    else
      _ -> false
    end
  end

  @doc """
  Newest extract dir for `feed_key` that still has `*.json.gz` shards.

  Used to resume a nist-nvd2 run after the worker pod dies mid-load.
  """
  @spec latest_extract(String.t(), Path.t()) :: map() | nil
  def latest_extract(feed_key, dir \\ root()) do
    feed_dir = Path.join(dir, feed_key)

    case File.ls(feed_dir) do
      {:ok, run_ids} ->
        run_ids
        |> Enum.map(&extract_info(Path.join(feed_dir, &1)))
        |> Enum.reject(&is_nil/1)
        |> Enum.max_by(& &1.mtime, fn -> nil end)

      _ ->
        nil
    end
  end

  defp extract_info(run_dir) do
    extracted_dir = Path.join(run_dir, "extracted")

    with true <- File.dir?(extracted_dir),
         {:ok, names} <- File.ls(extracted_dir),
         true <- Enum.any?(names, &String.ends_with?(&1, ".json.gz")),
         {:ok, %File.Stat{mtime: mtime}} <- File.stat(run_dir, time: :posix) do
      %{
        run_dir: run_dir,
        extracted_dir: extracted_dir,
        download_path: Path.join(run_dir, "download.zip"),
        mtime: mtime
      }
    else
      _ -> nil
    end
  end

  @doc """
  Create and return the per-run staging directory `<root>/<feed_key>/<run_id>/`.
  """
  @spec prepare_run(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def prepare_run(feed_key, run_id, dir \\ root()) do
    run_dir = Path.join([dir, feed_key, run_id])
    extracted_dir = Path.join(run_dir, "extracted")

    with :ok <- ensure_dir(extracted_dir) do
      {:ok,
       %{
         run_dir: run_dir,
         download_path: Path.join(run_dir, "download.zip"),
         extracted_dir: extracted_dir
       }}
    end
  end

  @doc "Remove a per-run staging directory (best-effort)."
  @spec cleanup_run(Path.t()) :: :ok
  def cleanup_run(run_dir) do
    _ = File.rm_rf(run_dir)
    :ok
  end

  @doc """
  Reap orphaned per-run directories older than `max_age_seconds` across all feeds.
  Safe to call on startup; never raises.
  """
  @spec reap_orphans(keyword()) :: {:ok, non_neg_integer()}
  def reap_orphans(opts \\ []) do
    dir = Keyword.get(opts, :root, root())
    max_age = Keyword.get(opts, :max_age_seconds, @orphan_max_age_seconds)
    now = Keyword.get(opts, :now, System.system_time(:second))

    reaped =
      dir
      |> run_dirs()
      |> Enum.count(fn run_dir ->
        case age_seconds(run_dir, now) do
          age when age > max_age ->
            File.rm_rf(run_dir)
            true

          _ ->
            false
        end
      end)

    {:ok, reaped}
  rescue
    error ->
      Logger.warning("advisory_feeds: orphan reap failed: #{inspect(error)}")
      {:ok, 0}
  end

  defp run_dirs(root) do
    case File.ls(root) do
      {:ok, feed_keys} ->
        Enum.flat_map(feed_keys, fn feed_key ->
          feed_dir = Path.join(root, feed_key)

          case File.ls(feed_dir) do
            {:ok, run_ids} -> Enum.map(run_ids, &Path.join(feed_dir, &1))
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  defp age_seconds(path, now) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> now - mtime
      _ -> 0
    end
  end

  defp ensure_dir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
