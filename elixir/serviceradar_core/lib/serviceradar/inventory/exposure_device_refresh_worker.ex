defmodule ServiceRadar.Inventory.ExposureDeviceRefreshWorker do
  @moduledoc """
  Republishes current actionable assessments after an authorized device restore.
  The source transaction queues the lifecycle; pages lock assessments before the
  ordinal, matching ordinary assessment writers. Queue progress is committed only
  after the page, never while holding a queue lock ahead of an ordinal lock.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 10,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Repo

  @page_size 500
  @pages_per_run 10

  @impl Oban.Worker
  def perform(_job) do
    drain(@pages_per_run)
  end

  defp drain(0), do: {:snooze, 1}

  defp drain(remaining) do
    case Repo.query!("""
         SELECT device_uid, lifecycle_seq FROM platform.exposure_device_refreshes
         ORDER BY inserted_at, device_uid LIMIT 1
         """).rows do
      [] ->
        :ok

      [[uid, lifecycle]] ->
        case refresh_page(uid, lifecycle) do
          {:ok, _} -> drain(remaining - 1)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp refresh_page(uid, lifecycle) do
    Repo.transaction(fn ->
      %{num_rows: changed} =
        Repo.query!(
          """
          WITH page AS MATERIALIZED (
            SELECT a.id FROM platform.endpoint_vulnerability_assessments a
            WHERE a.device_uid = $1
              AND platform.exposure_assessment_actionable(a.status, a.assessment, a.disposition)
              AND a.last_device_lifecycle_seq IS DISTINCT FROM $2::bigint
              AND EXISTS (SELECT 1 FROM platform.device_fleet_ordinals o
                WHERE o.uid = a.device_uid AND NOT o.tombstoned AND o.lifecycle_seq = $2)
            ORDER BY a.package_identity_key, a.cve_id LIMIT $3 FOR UPDATE
          )
          UPDATE platform.endpoint_vulnerability_assessments a
          SET last_transition_seq = a.last_transition_seq FROM page WHERE a.id = page.id
          """,
          [uid, lifecycle, @page_size]
        )

      if changed == 0 do
        Repo.query!(
          "DELETE FROM platform.exposure_device_refreshes WHERE device_uid = $1 AND lifecycle_seq = $2",
          [uid, lifecycle]
        )
      end
    end)
  end
end
