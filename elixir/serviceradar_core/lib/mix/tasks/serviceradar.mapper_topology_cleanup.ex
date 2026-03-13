defmodule Mix.Tasks.Serviceradar.MapperTopologyCleanup do
  @moduledoc """
  One-shot cleanup for mapper identity/topology drift.

  - Collapses active duplicate devices that share the same management IP.
  - Runs topology-link canonicalization/remap cleanup.

  Usage:
    mix serviceradar.mapper_topology_cleanup
  """

  # credo:disable-for-this-file Credo.Check.Refactor.Nesting

  use Mix.Task

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.NetworkDiscovery.TopologyStateCleanup
  alias ServiceRadar.Repo

  require Logger

  @shortdoc "Collapse duplicate mapper device identities and cleanup topology links"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    actor = SystemActor.system(:mapper_topology_cleanup)

    duplicate_sets = duplicate_ip_uid_sets()
    merge_stats = merge_duplicate_sets(duplicate_sets, actor)

    cleanup_stats =
      case TopologyStateCleanup.canonicalize_deleted_device_links() do
        {:ok, stats} ->
          stats

        {:error, reason} ->
          Logger.warning("Topology state cleanup failed after merge pass: #{inspect(reason)}")
          %{error: inspect(reason)}
      end

    Mix.shell().info("Mapper topology cleanup complete")
    Mix.shell().info("Duplicate IP groups: #{length(duplicate_sets)}")
    Mix.shell().info("Merged devices: #{merge_stats.merged}")
    Mix.shell().info("Merge failures: #{merge_stats.failed}")
    Mix.shell().info("Topology cleanup: #{inspect(cleanup_stats)}")
  end

  defp duplicate_ip_uid_sets do
    sql = """
    WITH ranked AS (
      SELECT
        ip,
        uid,
        row_number() OVER (
          PARTITION BY ip
          ORDER BY
            CASE WHEN COALESCE(metadata->>'identity_source', '') = 'mapper_topology_sighting' THEN 1 ELSE 0 END,
            CASE WHEN uid LIKE 'sr:%' THEN 0 ELSE 1 END,
            CASE
              WHEN COALESCE(metadata->>'identity_state', '') = 'canonical' THEN 0
              WHEN COALESCE(metadata->>'identity_state', '') = 'provisional' THEN 1
              ELSE 2
            END,
            uid
        ) AS rank
      FROM platform.ocsf_devices
      WHERE deleted_at IS NULL
        AND ip IS NOT NULL
        AND btrim(ip) <> ''
    ),
    grouped AS (
      SELECT
        ip,
        array_agg(uid ORDER BY rank) AS ordered_uids
      FROM ranked
      GROUP BY ip
      HAVING count(*) > 1
    )
    SELECT ip, ordered_uids FROM grouped ORDER BY ip
    """

    case Ecto.Adapters.SQL.query(Repo, sql, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [ip, ordered_uids] ->
          %{ip: ip, canonical: List.first(ordered_uids), duplicates: Enum.drop(ordered_uids, 1)}
        end)

      {:error, reason} ->
        Logger.warning("Failed to load duplicate mapper IP sets: #{inspect(reason)}")
        []
    end
  end

  defp merge_duplicate_sets(duplicate_sets, actor) do
    Enum.reduce(duplicate_sets, %{merged: 0, failed: 0}, fn set, acc ->
      Enum.reduce(set.duplicates, acc, fn duplicate_uid, inner_acc ->
        case IdentityReconciler.merge_devices(
               duplicate_uid,
               set.canonical,
               actor: actor,
               reason: "manual_mapper_ip_identity_collapse",
               details: %{"ip" => set.ip}
             ) do
          :ok ->
            %{inner_acc | merged: inner_acc.merged + 1}

          {:error, reason} ->
            Logger.warning(
              "Failed duplicate IP merge #{duplicate_uid} -> #{set.canonical} for #{set.ip}: #{inspect(reason)}"
            )

            %{inner_acc | failed: inner_acc.failed + 1}
        end
      end)
    end)
  end
end
