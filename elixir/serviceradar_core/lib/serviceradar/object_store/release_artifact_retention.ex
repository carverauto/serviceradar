defmodule ServiceRadar.ObjectStore.ReleaseArtifactRetention do
  @moduledoc """
  Reference-aware cleanup for mirrored agent release artifacts in datasvc object storage.
  """

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.DataService.Client, as: DataServiceClient
  alias ServiceRadar.Edge.AgentRelease
  alias ServiceRadar.Edge.AgentReleaseRollout
  alias ServiceRadar.Edge.AgentReleaseTarget
  alias ServiceRadar.Sync.Client, as: SyncClient

  require Ash.Query
  require Logger

  @prefix "agent-releases/"
  @terminal_target_statuses [:healthy, :failed, :rolled_back, :canceled]
  @active_rollout_statuses [:active, :paused]
  @epoch ~U[1970-01-01 00:00:00Z]

  @type summary :: %{
          scanned: non_neg_integer(),
          protected: non_neg_integer(),
          eligible: non_neg_integer(),
          deleted: non_neg_integer(),
          failed: non_neg_integer(),
          dry_run: boolean(),
          failures: [map()]
        }

  @spec run(keyword()) :: {:ok, summary()} | {:error, term()}
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run?, config(:dry_run?, true))
    keep_latest = Keyword.get(opts, :keep_latest, config(:agent_release_keep_latest, 1))
    timeout = Keyword.get(opts, :timeout, config(:datasvc_timeout_ms, 30_000))
    actor = SystemActor.system(:object_store_retention)

    with {:ok, releases} <- read_releases(actor),
         {:ok, protected_release_ids} <- protected_release_ids(releases, keep_latest, actor),
         {:ok, summary} <-
           with_datasvc_channel(releases, protected_release_ids, dry_run?, timeout) do
      Logger.info("ObjectStoreRetention: release artifact cleanup completed",
        scanned: summary.scanned,
        protected: summary.protected,
        eligible: summary.eligible,
        deleted: summary.deleted,
        failed: summary.failed,
        dry_run: summary.dry_run
      )

      {:ok, summary}
    end
  end

  @spec plan([AgentRelease.t()], MapSet.t(), [Proto.ObjectInfo.t()]) :: map()
  def plan(releases, protected_release_ids, objects) do
    releases_by_id = Map.new(releases, &{&1.id, &1})

    object_to_release_id =
      releases
      |> Enum.flat_map(fn release ->
        release
        |> artifact_keys()
        |> Enum.map(&{&1, release.id})
      end)
      |> Map.new()

    objects =
      Enum.map(objects, fn object ->
        key = object_key(object)
        release_id = Map.get(object_to_release_id, key)
        release = if release_id, do: Map.get(releases_by_id, release_id)

        cond do
          release_id && MapSet.member?(protected_release_ids, release_id) ->
            %{
              key: key,
              object: object,
              release: release,
              action: :protect,
              reason: :referenced_release
            }

          release_id ->
            %{
              key: key,
              object: object,
              release: release,
              action: :delete,
              reason: :retained_release_count_exceeded
            }

          true ->
            %{key: key, object: object, release: nil, action: :delete, reason: :orphaned_object}
        end
      end)

    %{
      objects: objects,
      protected: Enum.filter(objects, &(&1.action == :protect)),
      eligible: Enum.filter(objects, &(&1.action == :delete))
    }
  end

  defp read_releases(actor) do
    AgentRelease
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(updated_at: :desc, inserted_at: :desc, published_at: :desc)
    |> Ash.read(actor: actor)
  end

  @doc """
  Returns the release IDs protected by the local import/update retention window.
  """
  @spec retained_release_ids([AgentRelease.t()], integer()) :: MapSet.t()
  def retained_release_ids(releases, keep_latest) do
    releases
    |> sort_by_import_time()
    |> Enum.take(max(keep_latest, 0))
    |> MapSet.new(& &1.id)
  end

  defp protected_release_ids(releases, keep_latest, actor) do
    newest = retained_release_ids(releases, keep_latest)

    with {:ok, rollout_ids} <- active_rollout_release_ids(actor),
         {:ok, target_ids} <- active_target_release_ids(actor) do
      {:ok, newest |> MapSet.union(rollout_ids) |> MapSet.union(target_ids)}
    end
  end

  defp active_rollout_release_ids(actor) do
    AgentReleaseRollout
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(expr(status in ^@active_rollout_statuses))
    |> Ash.read(actor: actor)
    |> case do
      {:ok, rollouts} ->
        {:ok, MapSet.new(rollouts, & &1.release_id)}

      error ->
        error
    end
  end

  defp active_target_release_ids(actor) do
    AgentReleaseTarget
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(expr(status not in ^@terminal_target_statuses))
    |> Ash.read(actor: actor)
    |> case do
      {:ok, targets} ->
        {:ok, MapSet.new(targets, & &1.release_id)}

      error ->
        error
    end
  end

  defp with_datasvc_channel(releases, protected_release_ids, dry_run?, timeout) do
    DataServiceClient.with_channel(
      fn channel ->
        with {:ok, objects} <- list_datasvc_page(channel, "", [], timeout) do
          plan = plan(releases, protected_release_ids, objects)
          {:ok, execute_plan(plan, channel, dry_run?, timeout)}
        end
      end,
      timeout: timeout
    )
  end

  defp list_datasvc_page(channel, page_token, acc, timeout) do
    case SyncClient.list_objects(channel,
           prefix: @prefix,
           page_size: 500,
           page_token: page_token,
           timeout: timeout
         ) do
      {:ok, %Proto.ListObjectsResponse{objects: objects, next_page_token: next}}
      when next in [nil, ""] ->
        {:ok, acc ++ List.wrap(objects)}

      {:ok, %Proto.ListObjectsResponse{objects: objects, next_page_token: next}} ->
        list_datasvc_page(channel, next, acc ++ List.wrap(objects), timeout)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_plan(plan, channel, dry_run?, timeout) do
    eligible = Map.fetch!(plan, :eligible)

    {deleted, failures} =
      if dry_run? do
        {0, []}
      else
        delete_objects(eligible, channel, timeout)
      end

    %{
      scanned: length(Map.fetch!(plan, :objects)),
      protected: length(Map.fetch!(plan, :protected)),
      eligible: length(eligible),
      deleted: deleted,
      failed: length(failures),
      dry_run: dry_run?,
      failures: failures
    }
  end

  defp delete_objects(objects, channel, timeout) do
    Enum.reduce(objects, {0, []}, fn %{key: key, reason: reason}, {deleted, failures} ->
      case SyncClient.delete_object(channel, key, timeout: timeout) do
        {:ok, %Proto.DeleteObjectResponse{deleted: true}} ->
          {deleted + 1, failures}

        {:ok, %Proto.DeleteObjectResponse{deleted: false}} ->
          {deleted, failures}

        {:error, error} ->
          {deleted, [%{key: key, reason: reason, error: inspect(error)} | failures]}
      end
    end)
  end

  defp artifact_keys(%AgentRelease{metadata: metadata}) when is_map(metadata) do
    metadata
    |> get_in(["storage", "artifacts"])
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"object_key" => key} when is_binary(key) -> [key]
      %{object_key: key} when is_binary(key) -> [key]
      _ -> []
    end)
  end

  defp artifact_keys(_), do: []

  defp object_key(%Proto.ObjectInfo{metadata: %Proto.ObjectMetadata{key: key}}), do: key
  defp object_key(%{metadata: %{key: key}}), do: key
  defp object_key(%{key: key}), do: key

  defp sort_by_import_time(releases) do
    Enum.sort(releases, fn left, right ->
      compare_release_import_time(left, right)
    end)
  end

  defp compare_release_import_time(left, right) do
    left_key = release_import_key(left)
    right_key = release_import_key(right)

    case compare_datetime_keys(left_key, right_key) do
      :gt -> true
      :lt -> false
      :eq -> to_string(left.id) <= to_string(right.id)
    end
  end

  defp release_import_key(%AgentRelease{} = release) do
    [
      release.updated_at || @epoch,
      release.inserted_at || @epoch,
      release.published_at || @epoch
    ]
  end

  defp compare_datetime_keys([], []), do: :eq

  defp compare_datetime_keys([left | left_rest], [right | right_rest]) do
    case DateTime.compare(left, right) do
      :eq -> compare_datetime_keys(left_rest, right_rest)
      order -> order
    end
  end

  defp config(key, default) do
    :serviceradar_core
    |> Application.get_env(:object_store_retention, [])
    |> Keyword.get(key, default)
  end
end
