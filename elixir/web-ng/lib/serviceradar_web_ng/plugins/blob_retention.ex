defmodule ServiceRadarWebNG.Plugins.BlobRetention do
  @moduledoc """
  Reference-aware cleanup for plugin package blobs in the configured storage backend.
  """

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.{PluginAssignment, PluginPackage, PluginTargetPolicy}
  alias ServiceRadarWebNG.Plugins.Storage

  require Ash.Query
  require Logger

  @protected_statuses [:staged, :approved]
  @deletable_statuses [:denied, :revoked]

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run?, config(:dry_run?, true))
    grace_seconds = Keyword.get(opts, :plugin_orphan_grace_seconds, config(:plugin_orphan_grace_seconds, 604_800))
    actor = SystemActor.system(:plugin_blob_retention)

    with {:ok, packages} <- read_packages(actor),
         {:ok, referenced_ids} <- referenced_package_ids(actor),
         {:ok, blobs} <- Storage.list_blobs("plugins/") do
      plan = plan(packages, referenced_ids, blobs, grace_seconds)
      summary = execute_plan(plan, dry_run?)

      Logger.info("PluginBlobRetention: cleanup completed",
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

  @spec plan([PluginPackage.t()], MapSet.t(), [map()], non_neg_integer()) :: map()
  def plan(packages, referenced_ids, blobs, grace_seconds) do
    now = DateTime.utc_now()

    packages_by_key =
      packages
      |> Enum.flat_map(fn package ->
        case normalize_key(package.wasm_object_key) do
          nil -> []
          key -> [{key, package}]
        end
      end)
      |> Map.new()

    objects =
      Enum.map(blobs, fn blob ->
        key = normalize_key(Map.get(blob, :key) || Map.get(blob, "key"))
        package = Map.get(packages_by_key, key)

        cond do
          is_nil(key) ->
            %{key: key, blob: blob, package: package, action: :protect, reason: :invalid_key}

          is_nil(package) ->
            %{key: key, blob: blob, package: nil, action: :delete, reason: :orphaned_blob}

          package.status in @protected_statuses ->
            %{key: key, blob: blob, package: package, action: :protect, reason: :active_package}

          MapSet.member?(referenced_ids, package.id) ->
            %{key: key, blob: blob, package: package, action: :protect, reason: :referenced_package}

          package.status in @deletable_statuses and older_than?(package, now, grace_seconds) ->
            %{key: key, blob: blob, package: package, action: :delete, reason: :inactive_package}

          true ->
            %{key: key, blob: blob, package: package, action: :protect, reason: :grace_period}
        end
      end)

    %{
      objects: objects,
      protected: Enum.filter(objects, &(&1.action == :protect)),
      eligible: Enum.filter(objects, &(&1.action == :delete))
    }
  end

  defp read_packages(actor) do
    PluginPackage
    |> Ash.Query.for_read(:read)
    |> Ash.read(actor: actor)
  end

  defp referenced_package_ids(actor) do
    with {:ok, assignments} <- read_assignments(actor),
         {:ok, policies} <- read_policies(actor) do
      ids =
        assignments
        |> Enum.map(& &1.plugin_package_id)
        |> Enum.concat(Enum.map(policies, & &1.plugin_package_id))
        |> MapSet.new()

      {:ok, ids}
    end
  end

  defp read_assignments(actor) do
    PluginAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(expr(enabled == true))
    |> Ash.read(actor: actor)
  end

  defp read_policies(actor) do
    PluginTargetPolicy
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(expr(enabled == true))
    |> Ash.read(actor: actor)
  end

  defp execute_plan(plan, dry_run?) do
    eligible = Map.fetch!(plan, :eligible)

    {deleted, failures} =
      if dry_run? do
        {0, []}
      else
        delete_blobs(eligible)
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

  defp delete_blobs(objects) do
    Enum.reduce(objects, {0, []}, fn %{key: key, reason: reason}, {deleted, failures} ->
      case Storage.delete_blob(key) do
        :ok -> {deleted + 1, failures}
        {:error, error} -> {deleted, [%{key: key, reason: reason, error: inspect(error)} | failures]}
      end
    end)
  end

  defp older_than?(package, now, grace_seconds) do
    updated_at = package.updated_at || package.inserted_at

    case updated_at do
      %DateTime{} = datetime -> DateTime.diff(now, datetime, :second) >= grace_seconds
      _ -> false
    end
  end

  defp normalize_key(key) when is_binary(key) do
    key = String.trim(key)
    if key == "", do: nil, else: key
  end

  defp normalize_key(_), do: nil

  defp config(key, default) do
    :serviceradar_web_ng
    |> Application.get_env(:object_store_retention, [])
    |> Keyword.get(key, default)
  end
end
