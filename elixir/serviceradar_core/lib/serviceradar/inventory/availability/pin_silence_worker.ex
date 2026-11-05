defmodule ServiceRadar.Inventory.Availability.PinSilenceWorker do
  @moduledoc """
  Cuts the stale-pin detection window from 2×interval to 1×interval.

  The expiry worker fires when a per-agent ledger entry ages past its TTL
  (`2×interval + 5 min`). When the deciding agent (`availability_source_agent_id`)
  goes silent — blocked by NAC, rebooted, or reassigned — the device stays
  falsely `available` until the full TTL expires. For a 5-minute sweep that is
  a 15-minute blind window; for longer intervals it grows proportionally.

  This worker closes the gap: every minute it finds devices whose pin agent's
  last ledger entry is older than one sweep interval but still within the TTL
  window, immediately expires those entries by back-dating `checked_at`, and
  re-resolves the devices inline. The net effect is detection within one missed
  sweep cycle instead of two.

  The expiry worker's watermark-based scan is unchanged; this worker acts on a
  structural pattern (missed beat from the deciding agent) rather than a time
  slice, and the two do not overlap — the expiry worker sees entries whose TTL
  has already lapsed, this worker sees entries whose TTL has not yet lapsed.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 55, states: [:available, :scheduled]]

  alias ServiceRadar.Inventory.Availability.Resolution
  alias ServiceRadar.Repo

  require Logger

  @batch_size 500

  # Devices whose deciding agent has missed at least one sweep cycle but whose
  # ledger entry is still fresh (within TTL). Paged in uid order.
  @silent_pin_page """
  SELECT DISTINCT a.device_uid
  FROM platform.device_agent_availability AS a
  JOIN platform.ocsf_devices AS d
    ON d.uid = a.device_uid
    AND d.availability_source_agent_id = a.agent_id
    AND d.availability_state = 'available'
    AND d.deleted_at IS NULL
  JOIN platform.sweep_groups AS g ON g.id = a.sweep_group_id
    AND g."interval" ~* '^[0-9]{1,9}[smhd]$'
  WHERE a.available = true
    AND a.checked_at < (
      clock_timestamp() AT TIME ZONE 'utc' - (
        CASE lower(right(g."interval", 1))
          WHEN 's' THEN substring(g."interval" FROM '^([0-9]{1,9})')::bigint * interval '1 second'
          WHEN 'm' THEN substring(g."interval" FROM '^([0-9]{1,9})')::bigint * interval '1 minute'
          WHEN 'h' THEN substring(g."interval" FROM '^([0-9]{1,9})')::bigint * interval '1 hour'
          ELSE substring(g."interval" FROM '^([0-9]{1,9})')::bigint * interval '1 day'
        END
      )
    )
    AND a.checked_at + platform.availability_ledger_ttl(a.sweep_group_id) >
        clock_timestamp() AT TIME ZONE 'utc'
    AND a.device_uid > $1::text
  ORDER BY a.device_uid
  LIMIT $2
  """

  # Expire the pin agent's ledger entries for the matched devices so the
  # resolver sees them as stale on the inline re-resolution below.
  @expire_entries """
  UPDATE platform.device_agent_availability AS a
  SET checked_at = '2000-01-01'::timestamp
  FROM platform.ocsf_devices AS d
  WHERE d.uid = a.device_uid
    AND d.availability_source_agent_id = a.agent_id
    AND d.availability_state = 'available'
    AND d.uid = ANY($1::text[])
    AND a.available = true
  """

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    total = expire_silent_pins("", 0)

    if total > 0 do
      Logger.info(
        "pin_silence: re-resolved #{total} device(s) whose deciding agent missed a sweep"
      )
    end

    :ok
  end

  defp expire_silent_pins(cursor, total) do
    %{rows: rows} = Repo.query!(@silent_pin_page, [cursor, @batch_size])

    case Enum.map(rows, &hd/1) do
      [] ->
        total

      uids ->
        {:ok, result} =
          Repo.transaction(fn ->
            Repo.query!(@expire_entries, [uids])
            Resolution.resolve_locked(uids)
          end)

        :telemetry.execute(
          [:serviceradar, :availability, :pin_silence],
          %{resolved: result.resolved, written: result.written},
          %{}
        )

        expire_silent_pins(List.last(uids), total + length(uids))
    end
  end
end
