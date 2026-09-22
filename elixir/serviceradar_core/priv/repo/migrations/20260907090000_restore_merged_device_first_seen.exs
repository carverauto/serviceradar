defmodule ServiceRadar.Repo.Migrations.RestoreMergedDeviceFirstSeen do
  @moduledoc """
  Pull each merge survivor's `first_seen_time` back to the earliest date any
  device in its transitive active merge chain was first seen.

  `MergeEngine.preserve_survivor_attributes/2` carries tags, metadata, type and
  discovery sources from the merged-away device to the survivor, but never
  carried `first_seen_time`. When the survivor is the NEWER row -- which is the
  common shape, because a census sighting of a fresh address is minted first and
  only later recognised as an already-known device -- the merge kept the
  survivor's own creation date and discarded the earlier one.

  The visible effect is the "Recently added devices" report
  (`in:devices first_seen:last_30d`, `Dashboards.SystemReports`), which then
  lists already-known hosts as new (GitHub #4381).

  The forward fix is in `preserve_survivor_attributes/2`. This repairs the rows
  already merged, and derives entirely from `platform.merge_audit` -- the
  authoritative record of what merged into what -- joined back to the
  merged-away rows themselves, which a merge tombstones rather than deletes, so
  their dates are still there to read.

  Active edges exclude unmerge events and the original events they reverse,
  identified by `details.original_merge_event_id`. Recursive `UNION` deduplicates
  device/date pairs so cycles terminate without losing earlier dates.

  The `WHERE` only ever lowers a date, so a survivor that was already the older
  row keeps what it has and a second run updates nothing. Merged-away rows count
  as sources whether or not they are tombstoned; a source with no recorded date
  is skipped rather than treated as the earliest.
  """
  use Ecto.Migration

  def up do
    execute(repair_sql(prefix() || "platform"))
  end

  def repair_sql(schema) do
    """
    WITH RECURSIVE active_merges AS (
      SELECT m.from_device_id, m.to_device_id
      FROM #{schema}.merge_audit m
      WHERE m.reason IS DISTINCT FROM 'unmerge'
        AND NOT EXISTS (
          SELECT 1
          FROM #{schema}.merge_audit reversal
          WHERE reversal.reason = 'unmerge'
            AND reversal.details->>'original_merge_event_id' = m.event_id::text
        )
    ), inherited_dates (uid, first_seen_time) AS (
      SELECT m.to_device_id, src.first_seen_time
      FROM active_merges m
      JOIN #{schema}.ocsf_devices src ON src.uid = m.from_device_id
      WHERE src.first_seen_time IS NOT NULL
      UNION
      SELECT m.to_device_id, inherited.first_seen_time
      FROM inherited_dates inherited
      JOIN active_merges m ON m.from_device_id = inherited.uid
    ), earliest AS (
      SELECT uid, MIN(first_seen_time) AS first_seen_time
      FROM inherited_dates
      GROUP BY uid
    )
    UPDATE #{schema}.ocsf_devices d
    SET first_seen_time = earliest.first_seen_time,
        modified_time = timezone('utc', now())
    FROM earliest
    WHERE d.uid = earliest.uid
      AND (d.first_seen_time IS NULL OR d.first_seen_time > earliest.first_seen_time)
    """
  end

  def down do
    # The discarded dates are not recorded anywhere, so there is nothing to
    # restore them from -- and re-raising a survivor's first_seen_time would
    # reintroduce the defect this migration exists to repair.
    :ok
  end
end
