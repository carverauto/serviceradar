defmodule ServiceRadarWebNG.Dashboards.PackageRetention do
  @moduledoc """
  Version-count retention for dashboard packages.

  For each distinct `dashboard_id`, keeps the N most-recent versions by
  `inserted_at` and deletes older ones — blob from the object store first,
  then the DB record. Protected packages are never deleted regardless of
  version count:

    * `status == :enabled` — actively serving dashboard traffic.
    * Referenced by any `DashboardInstance` — the FK carries `on_delete: :delete`,
      so removing the package would cascade-delete the instance row.
    * Within the retention window — the `keep_versions` newest per dashboard_id.

  At least one version is always kept per dashboard_id even when all versions
  are disabled (enforced by clamping keep_versions to a minimum of 1).
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Dashboards.DashboardInstance
  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadarWebNG.Plugins.Storage

  require Ash.Query
  require Logger

  @type summary :: %{
          scanned: non_neg_integer(),
          protected: non_neg_integer(),
          eligible: non_neg_integer(),
          deleted_blobs: non_neg_integer(),
          deleted_records: non_neg_integer(),
          failed: non_neg_integer(),
          dry_run: boolean(),
          failures: [map()]
        }

  @spec run(keyword()) :: {:ok, summary()} | {:error, term()}
  def run(opts \\ []) do
    keep_versions = max(1, Keyword.get(opts, :keep_versions, 2))
    dry_run? = Keyword.get(opts, :dry_run?, false)
    actor = SystemActor.system(:dashboard_package_retention)

    with {:ok, all_packages} <- read_all_packages(actor),
         {:ok, instanced_ids} <- read_instanced_package_ids(actor) do
      plan = build_plan(all_packages, instanced_ids, keep_versions)
      summary = execute_plan(plan, dry_run?, actor)

      Logger.info("DashboardPackageRetention plan built",
        dashboard_groups: map_size(Enum.group_by(all_packages, & &1.dashboard_id)),
        scanned: summary.scanned,
        protected: summary.protected,
        eligible: summary.eligible
      )

      {:ok, summary}
    end
  end

  @doc false
  @spec build_plan([DashboardPackage.t()], MapSet.t(), pos_integer()) :: map()
  def build_plan(packages, instanced_ids, keep_versions) do
    entries =
      packages
      |> Enum.group_by(& &1.dashboard_id)
      |> Enum.flat_map(fn {_dashboard_id, group} ->
        sorted = Enum.sort_by(group, & &1.inserted_at, {:desc, DateTime})
        {keep_set, eligible_list} = split_group(sorted, keep_versions)

        Enum.map(sorted, fn pkg ->
          cond do
            pkg.status == :enabled ->
              %{package: pkg, action: :protect, reason: :enabled_package}

            MapSet.member?(instanced_ids, pkg.id) ->
              %{package: pkg, action: :protect, reason: :has_instance}

            MapSet.member?(keep_set, pkg.id) ->
              %{package: pkg, action: :protect, reason: :within_retention_window}

            pkg in eligible_list ->
              %{package: pkg, action: :delete, reason: :exceeds_retention_count}

            true ->
              %{package: pkg, action: :protect, reason: :within_retention_window}
          end
        end)
      end)

    %{
      all: entries,
      protected: Enum.filter(entries, &(&1.action == :protect)),
      eligible: Enum.filter(entries, &(&1.action == :delete))
    }
  end

  defp split_group(sorted, keep_versions) do
    {keep_list, eligible_list} = Enum.split(sorted, keep_versions)
    {MapSet.new(keep_list, & &1.id), eligible_list}
  end

  defp read_all_packages(actor) do
    DashboardPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read(actor: actor)
  end

  defp read_instanced_package_ids(actor) do
    DashboardInstance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.select([:dashboard_package_id])
    |> Ash.read(actor: actor)
    |> case do
      {:ok, instances} ->
        {:ok, MapSet.new(instances, & &1.dashboard_package_id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_plan(plan, dry_run?, actor) do
    eligible = Map.fetch!(plan, :eligible)

    {deleted_blobs, deleted_records, failures} =
      if dry_run? do
        {0, 0, []}
      else
        delete_packages(eligible, actor)
      end

    %{
      scanned: length(Map.fetch!(plan, :all)),
      protected: length(Map.fetch!(plan, :protected)),
      eligible: length(eligible),
      deleted_blobs: deleted_blobs,
      deleted_records: deleted_records,
      failed: length(failures),
      dry_run: dry_run?,
      failures: failures
    }
  end

  defp delete_packages(entries, actor) do
    Enum.reduce(entries, {0, 0, []}, fn %{package: pkg}, {blobs, records, failures} ->
      case delete_one(pkg, actor) do
        {:ok, blob_deleted?} ->
          {blobs + if(blob_deleted?, do: 1, else: 0), records + 1, failures}

        {:error, reason} ->
          failure = %{
            package_id: pkg.id,
            dashboard_id: pkg.dashboard_id,
            version: pkg.version,
            reason: inspect(reason)
          }

          {blobs, records, [failure | failures]}
      end
    end)
  end

  defp delete_one(%DashboardPackage{} = pkg, actor) do
    blob_deleted? =
      case pkg.wasm_object_key do
        nil ->
          false

        key ->
          case Storage.delete_blob(key) do
            :ok ->
              true

            {:error, blob_reason} ->
              Logger.warning("DashboardPackageRetention: blob delete failed",
                package_id: pkg.id,
                object_key: key,
                reason: inspect(blob_reason)
              )

              false
          end
      end

    case Ash.destroy(pkg, actor: actor) do
      :ok -> {:ok, blob_deleted?}
      {:ok, _} -> {:ok, blob_deleted?}
      {:error, reason} -> {:error, reason}
    end
  end
end
