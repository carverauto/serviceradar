defmodule ServiceRadar.Inventory.AdvisoryFeeds.Staging do
  @moduledoc """
  On-disk staging for advisory feed downloads (design D2).

  Layout, rooted at `SERVICERADAR_ADVISORY_STAGING_DIR`
  (default `/var/lib/serviceradar/advisory-feeds`):

      <root>/<feed_key>/<run_id>/
        download.zip            # streamed from the presigned URL to disk
        extracted/              # unzip output (json, or *.json.gz shards)

  The staging volume MUST be a real mounted volume; when it is absent the large
  nist-nvd2 feed fails closed (never an in-memory fallback).

  Oban timeouts kill the worker with `:kill`, so `after` cleanup does not run.
  Combined with a new run id per attempt and local-path ignoring PVC size,
  leftover nist-nvd2 extracts filled a demo node (~255 GiB). Always keep at
  most one executing run dir for the large nist-nvd2 and Ubuntu feeds, reap the
  rest on every scheduler tick, and refuse downloads when staging is over budget.
  """

  require Logger

  @default_root "/var/lib/serviceradar/advisory-feeds"
  # Age-based backstop for tiny KEV dirs. nist-nvd2 is pruned by count, not age.
  @orphan_max_age_seconds 2 * 60 * 60
  # Zip + extracted shards must fit with headroom. local-path has no quota, so
  # this is the real disk cap.
  @max_staging_bytes 6 * 1024 * 1024 * 1024
  @min_free_bytes 4 * 1024 * 1024 * 1024

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
  Keep at most `keep` newest run dirs for `feed_key`; delete the rest now.

  This is the disk-safety valve for nist-nvd2. Timeout-killed jobs cannot run
  `after` cleanup, so the scheduler must drop extras every tick.
  """
  @spec prune_feed(String.t(), keyword()) :: {:ok, non_neg_integer()}
  def prune_feed(feed_key, opts \\ []) when is_binary(feed_key) do
    dir = Keyword.get(opts, :root, root())
    keep = Keyword.get(opts, :keep, 1)
    feed_dir = Path.join(dir, feed_key)

    run_dirs = newest_run_dirs(feed_dir)

    extras = Enum.drop(run_dirs, max(keep, 0))

    Enum.each(extras, fn run_dir ->
      File.rm_rf(run_dir)
    end)

    {:ok, length(extras)}
  rescue
    error ->
      Logger.warning("advisory_feeds: prune #{feed_key} failed: #{inspect(error)}")
      {:ok, 0}
  end

  @doc "Bytes used under the staging root (best-effort)."
  @spec usage_bytes(Path.t()) :: non_neg_integer()
  def usage_bytes(dir \\ root()) do
    dir
    |> Path.expand()
    |> usage_bytes_path()
  end

  @doc """
  Refuse a new nist-nvd2 download when staging is already over budget or the
  filesystem has too little free space. Call after pruning.
  """
  @spec ensure_budget(keyword()) :: :ok | {:error, term()}
  def ensure_budget(opts \\ []) do
    dir = Keyword.get(opts, :root, root())
    max_bytes = Keyword.get(opts, :max_bytes, @max_staging_bytes)
    min_free = Keyword.get(opts, :min_free_bytes, @min_free_bytes)
    used = usage_bytes(dir)

    cond do
      used > max_bytes ->
        {:error, {:staging_over_budget, used}}

      match?({:ok, free} when free < min_free, free_bytes(dir)) ->
        {:ok, free} = free_bytes(dir)
        {:error, {:staging_low_free, free}}

      true ->
        :ok
    end
  end

  @doc """
  Reap orphaned per-run directories older than `max_age_seconds` across all feeds.
  Always prunes nist-nvd2 and Ubuntu down to their executing-aware keep counts first.
  Safe to call on startup; never raises.
  """
  @spec reap_orphans(keyword()) :: {:ok, non_neg_integer()}
  def reap_orphans(opts \\ []) do
    dir = Keyword.get(opts, :root, root())
    max_age = Keyword.get(opts, :max_age_seconds, @orphan_max_age_seconds)
    now = Keyword.get(opts, :now, System.system_time(:second))
    nist_keep = Keyword.get(opts, :nist_keep, 1)

    ubuntu_keep = Keyword.get(opts, :ubuntu_keep, 1)
    {:ok, nist_pruned} = prune_feed("nist-nvd2", root: dir, keep: nist_keep)
    {:ok, ubuntu_pruned} = prune_feed("ubuntu-osv-vex", root: dir, keep: ubuntu_keep)

    protected =
      [{"nist-nvd2", nist_keep}, {"ubuntu-osv-vex", ubuntu_keep}]
      |> Enum.flat_map(fn {feed_key, keep} ->
        dir
        |> Path.join(feed_key)
        |> newest_run_dirs()
        |> Enum.take(max(keep, 0))
      end)
      |> MapSet.new()

    reaped =
      dir
      |> run_dirs()
      |> Enum.count(fn run_dir ->
        if MapSet.member?(protected, run_dir) do
          false
        else
          case age_seconds(run_dir, now) do
            age when age > max_age ->
              File.rm_rf(run_dir)
              true

            _ ->
              false
          end
        end
      end)

    {:ok, nist_pruned + ubuntu_pruned + reaped}
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

  defp newest_run_dirs(feed_dir) do
    case File.ls(feed_dir) do
      {:ok, run_ids} ->
        run_ids
        |> Enum.map(&Path.join(feed_dir, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.sort_by(&mtime/1, :desc)

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

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      _ -> 0
    end
  end

  defp usage_bytes_path(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        size

      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(path) do
          {:ok, names} ->
            Enum.reduce(names, 0, fn name, acc ->
              acc + usage_bytes_path(Path.join(path, name))
            end)

          _ ->
            0
        end

      _ ->
        0
    end
  end

  defp free_bytes(path) do
    case System.cmd("df", ["-Pk", path], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> List.last()
        |> String.split()
        |> Enum.at(3)
        |> parse_df_kib()

      _ ->
        :unknown
    end
  rescue
    _ -> :unknown
  end

  defp parse_df_kib(value) when is_binary(value) do
    case Integer.parse(value) do
      {kib, _} -> {:ok, kib * 1024}
      :error -> :unknown
    end
  end

  defp parse_df_kib(_), do: :unknown
end
