defmodule ServiceRadar.ObjectStore.NativeAddonArtifactRetention do
  @moduledoc """
  Reference-aware cleanup and liveness reconciliation for native add-on artifacts.
  """

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.DataService.Client, as: DataServiceClient
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.AddonProfile
  alias ServiceRadar.Sync.Client, as: SyncClient

  require Ash.Query
  require Logger

  @prefix "native-addons/"
  @protected_statuses [:staged, :approved]
  @deletable_statuses [:denied, :revoked]
  @verified_status "verified"
  @blob_missing_status "blob_missing"

  @type summary :: %{
          scanned: non_neg_integer(),
          protected: non_neg_integer(),
          eligible: non_neg_integer(),
          deleted: non_neg_integer(),
          failed: non_neg_integer(),
          missing: non_neg_integer(),
          dry_run: boolean(),
          failures: [map()]
        }

  @spec run(keyword()) :: {:ok, summary()} | {:error, term()}
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run?, config(:dry_run?, true))

    grace_seconds =
      Keyword.get(
        opts,
        :native_addon_orphan_grace_seconds,
        config(:native_addon_orphan_grace_seconds, 604_800)
      )

    timeout = Keyword.get(opts, :timeout, config(:datasvc_timeout_ms, 30_000))
    actor = SystemActor.system(:native_addon_artifact_retention)

    with {:ok, packages} <- read_packages(actor),
         {:ok, referenced_ids} <- referenced_package_ids(actor),
         {:ok, summary} <-
           with_datasvc_channel(packages, referenced_ids, grace_seconds, dry_run?, timeout, actor) do
      Logger.info("NativeAddonArtifactRetention: cleanup completed",
        scanned: summary.scanned,
        protected: summary.protected,
        eligible: summary.eligible,
        deleted: summary.deleted,
        failed: summary.failed,
        missing: summary.missing,
        dry_run: summary.dry_run
      )

      {:ok, summary}
    end
  end

  @spec plan([AddonPackage.t()], MapSet.t(), [Proto.ObjectInfo.t() | map()], non_neg_integer()) ::
          map()
  def plan(packages, referenced_ids, objects, grace_seconds) do
    now = DateTime.utc_now()

    packages_by_key =
      packages
      |> Enum.flat_map(fn package ->
        package
        |> artifact_keys()
        |> Enum.map(&{&1, package})
      end)
      |> Enum.group_by(fn {key, _package} -> key end, fn {_key, package} -> package end)

    objects =
      Enum.map(objects, fn object ->
        key = object_key(object)
        packages = Map.get(packages_by_key, key, [])
        package = List.first(packages)

        cond do
          is_nil(key) ->
            %{key: key, object: object, package: package, action: :protect, reason: :invalid_key}

          packages == [] and object_older_than?(object, now, grace_seconds) ->
            %{key: key, object: object, package: nil, action: :delete, reason: :orphaned_object}

          packages == [] ->
            %{key: key, object: object, package: nil, action: :protect, reason: :grace_period}

          Enum.any?(packages, &verified_package?/1) ->
            %{
              key: key,
              object: object,
              package: package,
              action: :protect,
              reason: :verified_package
            }

          Enum.any?(packages, &(&1.status in @protected_statuses)) ->
            %{
              key: key,
              object: object,
              package: package,
              action: :protect,
              reason: :active_package
            }

          Enum.any?(packages, &MapSet.member?(referenced_ids, &1.id)) ->
            %{
              key: key,
              object: object,
              package: package,
              action: :protect,
              reason: :referenced_package
            }

          Enum.all?(
            packages,
            &(&1.status in @deletable_statuses and older_than?(&1, now, grace_seconds))
          ) ->
            %{
              key: key,
              object: object,
              package: package,
              action: :delete,
              reason: :inactive_package
            }

          true ->
            %{key: key, object: object, package: package, action: :protect, reason: :grace_period}
        end
      end)

    %{
      objects: objects,
      protected: Enum.filter(objects, &(&1.action == :protect)),
      eligible: Enum.filter(objects, &(&1.action == :delete))
    }
  end

  @spec artifact_keys(AddonPackage.t() | map()) :: [String.t()]
  def artifact_keys(%AddonPackage{artifacts: artifacts}) when is_map(artifacts) do
    artifacts
    |> Map.values()
    |> Enum.flat_map(&artifact_entry_keys/1)
    |> Enum.uniq()
  end

  def artifact_keys(_package), do: []

  defp read_packages(actor) do
    AddonPackage
    |> Ash.Query.for_read(:read)
    |> Ash.read(actor: actor)
  end

  defp referenced_package_ids(actor) do
    with {:ok, assignments} <- read_assignments(actor),
         {:ok, profiles} <- read_profiles(actor) do
      ids =
        assignments
        |> Enum.map(& &1.addon_package_id)
        |> Enum.concat(Enum.map(profiles, & &1.addon_package_id))
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      {:ok, ids}
    end
  end

  defp read_assignments(actor) do
    AddonAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(expr(enabled == true))
    |> Ash.read(actor: actor)
  end

  defp read_profiles(actor) do
    AddonProfile
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(expr(enabled == true))
    |> Ash.read(actor: actor)
  end

  defp with_datasvc_channel(packages, referenced_ids, grace_seconds, dry_run?, timeout, actor) do
    DataServiceClient.with_channel(
      fn channel ->
        with {:ok, objects} <- list_datasvc_page(channel, "", [], timeout),
             {:ok, missing_count} <- reconcile_missing_blobs(channel, packages, timeout, actor) do
          plan = plan(packages, referenced_ids, objects, grace_seconds)
          {:ok, execute_plan(plan, channel, dry_run?, timeout, missing_count)}
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

  defp reconcile_missing_blobs(channel, packages, timeout, actor) do
    packages
    |> Enum.filter(&approved_for_liveness?/1)
    |> Enum.reduce_while({:ok, 0}, fn package, {:ok, missing_count} ->
      case reconcile_package_blobs(channel, package, timeout, actor) do
        {:ok, :present} -> {:cont, {:ok, missing_count}}
        {:ok, :missing} -> {:cont, {:ok, missing_count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp reconcile_package_blobs(channel, %AddonPackage{} = package, timeout, actor) do
    case missing_artifact_keys(channel, package, timeout) do
      {:ok, []} ->
        {:ok, :present}

      {:ok, missing_keys} ->
        with {:ok, _package} <- mark_package_blob_missing(package, missing_keys, actor) do
          {:ok, :missing}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp missing_artifact_keys(channel, %AddonPackage{} = package, timeout) do
    package
    |> artifact_keys()
    |> Enum.reduce_while({:ok, []}, fn key, {:ok, missing_keys} ->
      case object_liveness(channel, key, timeout) do
        :present -> {:cont, {:ok, missing_keys}}
        :missing -> {:cont, {:ok, [key | missing_keys]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, missing_keys} -> {:ok, Enum.reverse(missing_keys)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_package_blob_missing(%AddonPackage{} = package, missing_keys, actor) do
    message = "native add-on artifact object missing: #{Enum.join(missing_keys, ", ")}"

    package
    |> Ash.Changeset.for_update(:update, %{
      verification_status: @blob_missing_status,
      verification_error: message
    })
    |> Ash.update(actor: actor)
  end

  defp object_liveness(channel, key, timeout) do
    case SyncClient.get_object_info(channel, key, timeout: timeout) do
      {:ok, %Proto.GetObjectInfoResponse{found: true}} -> :present
      {:ok, %Proto.GetObjectInfoResponse{found: false}} -> :missing
      {:error, reason} -> if missing_object_error?(reason), do: :missing, else: {:error, reason}
    end
  end

  defp execute_plan(plan, channel, dry_run?, timeout, missing_count) do
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
      missing: missing_count,
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

  defp approved_for_liveness?(%AddonPackage{status: :approved} = package) do
    artifact_keys(package) != [] and package.verification_status != @blob_missing_status
  end

  defp approved_for_liveness?(_package), do: false

  defp verified_package?(%AddonPackage{status: status, verification_status: @verified_status})
       when status not in @deletable_statuses, do: true

  defp verified_package?(_package), do: false

  defp missing_object_error?(%GRPC.RPCError{status: 5}), do: true
  defp missing_object_error?(_reason), do: false

  defp artifact_entry_keys(entry) when is_map(entry) do
    case normalize_key(Map.get(entry, "object_key") || Map.get(entry, :object_key)) do
      key when is_binary(key) -> [key]
      _ -> []
    end
  end

  defp artifact_entry_keys(_entry), do: []

  defp object_key(%Proto.ObjectInfo{metadata: %Proto.ObjectMetadata{key: key}}),
    do: normalize_key(key)

  defp object_key(%{metadata: %{key: key}}), do: normalize_key(key)
  defp object_key(%{"metadata" => %{"key" => key}}), do: normalize_key(key)
  defp object_key(%{key: key}), do: normalize_key(key)
  defp object_key(%{"key" => key}), do: normalize_key(key)
  defp object_key(_object), do: nil

  defp normalize_key(key) when is_binary(key) do
    key = String.trim(key)
    if key == "", do: nil, else: key
  end

  defp normalize_key(_key), do: nil

  defp older_than?(package, now, grace_seconds) do
    updated_at = package.updated_at || package.inserted_at

    case updated_at do
      %DateTime{} = datetime -> DateTime.diff(now, datetime, :second) >= grace_seconds
      _ -> false
    end
  end

  defp object_older_than?(object, now, grace_seconds) do
    object
    |> object_created_at_unix()
    |> case do
      timestamp when is_integer(timestamp) and timestamp > 0 ->
        case DateTime.from_unix(timestamp) do
          {:ok, created_at} -> DateTime.diff(now, created_at, :second) >= grace_seconds
          _ -> false
        end

      _ ->
        false
    end
  end

  defp object_created_at_unix(%Proto.ObjectInfo{created_at_unix: timestamp}), do: timestamp
  defp object_created_at_unix(%{created_at_unix: timestamp}), do: timestamp
  defp object_created_at_unix(%{"created_at_unix" => timestamp}), do: timestamp
  defp object_created_at_unix(%{"createdAtUnix" => timestamp}), do: timestamp
  defp object_created_at_unix(_object), do: nil

  defp config(key, default) do
    :serviceradar_core
    |> Application.get_env(:object_store_retention, [])
    |> Keyword.get(key, default)
  end
end
