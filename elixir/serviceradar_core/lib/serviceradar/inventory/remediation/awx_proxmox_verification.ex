defmodule ServiceRadar.Inventory.Remediation.AwxProxmoxVerification do
  @moduledoc """
  Step `awx-proxmox-verify`: read-only checks of the `awx-proxmox-unmerge` repair, refused under
  execute. It reads the database only, so it runs before the repair, after it, and after any
  number of later syncs:

    * `A1` — every pair the step unmerged is still two records: neither record, followed through
      the merges that took it away, has reached the other;
    * `A2` — no AWX merge still in place is proved to join two different machines
      (`Decisions.awx_merge_evidence/1`), wherever it came from;
    * `A3` — no such merge was made after the repair started (the regression check of
      `fix-awx-proxmox-guest-binding-evidence`); `not_run` before any repair;
    * `A4` — no MAC row the step archived is back on the record it was taken from;
    * `A5` — every unmerged pair is still asserted distinct.

  A failing check counts in `verification_failures`, which fails the run. `settled` says whether
  every AWX controller and every guest the repair touched has been observed again since the
  repair finished; until then a pass says nothing about whether the result holds, and
  `verification_pending` is 1.
  """

  alias ServiceRadar.Inventory.Remediation.AwxProxmoxUnmerge
  alias ServiceRadar.Repo

  @sample 50
  @max_follow 32

  @doc false
  def run(_mode, opts, _manifest, _actor) do
    pairs = unmerged_pairs()
    repair_started = pairs |> Enum.map(& &1.unmerged_at) |> Enum.min(DateTime, fn -> nil end)
    repair_finished = repair_finished(pairs)

    data = AwxProxmoxUnmerge.load(opts)
    plan = AwxProxmoxUnmerge.plan(data, opts)

    remaining =
      Enum.filter(plan.report, &(&1.bad? and &1.disposition != :already_unmerged))

    checks = [
      check("A1", rejoined(pairs)),
      check("A2", Enum.map(remaining, &bad_sample/1)),
      new_bad_check(remaining, repair_started),
      check("A4", returned_macs()),
      check("A5", unasserted(pairs))
    ]

    settled = settled?(pairs, repair_finished)
    failures = Enum.count(checks, &(&1.status == "fail"))

    %{
      unmerged_pairs: length(pairs),
      repair_started_at: repair_started,
      repair_finished_at: repair_finished,
      settled: settled,
      candidate_limit_reached: data.truncated?,
      checks: checks,
      verification_failures: failures,
      verification_pending: if(settled, do: 0, else: 1)
    }
  end

  defp check(name, findings) do
    %{
      check: name,
      status: if(findings == [], do: "pass", else: "fail"),
      count: length(findings),
      sample: Enum.take(findings, @sample)
    }
  end

  defp new_bad_check(_remaining, nil), do: %{check: "A3", status: "not_run", count: 0, sample: []}

  defp new_bad_check(remaining, started) do
    remaining
    |> Enum.filter(&DateTime.after?(&1.created_at, started))
    |> Enum.map(&bad_sample/1)
    |> then(&check("A3", &1))
  end

  defp bad_sample(entry) do
    %{
      event_id: entry.event_id,
      created_at: entry.created_at,
      from_uid: entry.from_uid,
      to_uid: entry.to_uid,
      disposition: to_string(entry.disposition),
      proofs: Enum.map(entry.evidence.proofs, &to_string/1)
    }
  end

  defp unmerged_pairs do
    %{rows: rows} =
      query!(
        """
        SELECT u.to_device_id, u.from_device_id, u.details->>'original_merge_event_id',
               u.created_at
        FROM platform.merge_audit u
        WHERE u.reason = 'unmerge' AND u.details->>'unmerged_by' = $1
        """,
        [AwxProxmoxUnmerge.unmerged_by()]
      )

    Enum.map(rows, fn [merged, survivor, event_id, at] ->
      %{merged: merged, survivor: survivor, event_id: event_id, unmerged_at: utc(at)}
    end)
  end

  defp repair_finished(pairs) do
    %{rows: [[archived_at]]} =
      query!(
        "SELECT max(archived_at) FROM platform.device_identifier_archive WHERE archive_reason = $1",
        [AwxProxmoxUnmerge.archive_reason()]
      )

    [utc_or_nil(archived_at) | Enum.map(pairs, & &1.unmerged_at)]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp rejoined(pairs) do
    for pair <- pairs,
        merged = follow(pair.merged),
        merged == follow(pair.survivor),
        do: %{event_id: pair.event_id, merged: pair.merged, survivor: pair.survivor, now: merged}
  end

  # Where a record is now: itself while it is not a merge tombstone, otherwise the record its
  # newest unreversed merge took it to, followed in turn.
  defp follow(uid, depth \\ 0)
  defp follow(uid, depth) when depth >= @max_follow, do: uid

  defp follow(uid, depth) do
    %{rows: rows} =
      query!(
        """
        SELECT m.to_device_id
        FROM platform.ocsf_devices d
        JOIN platform.merge_audit m ON m.from_device_id = d.uid
        WHERE d.uid = $1 AND d.deleted_at IS NOT NULL AND d.deleted_reason = 'merged'
          AND m.reason IS DISTINCT FROM 'unmerge'
          AND NOT EXISTS (
            SELECT 1 FROM platform.merge_audit u
            WHERE u.reason = 'unmerge'
              AND u.details->>'original_merge_event_id' = m.event_id::text
          )
        ORDER BY m.created_at DESC NULLS LAST
        LIMIT 1
        """,
        [uid]
      )

    case rows do
      [[next]] -> follow(next, depth + 1)
      [] -> uid
    end
  end

  defp returned_macs do
    %{rows: rows} =
      query!(
        """
        SELECT a.id, a.device_id, a.identifier_value
        FROM platform.device_identifier_archive a
        JOIN platform.device_identifiers di
          ON di.identifier_type = a.identifier_type
         AND di.identifier_value = a.identifier_value
         AND di.partition = a.partition
         AND di.device_id = a.device_id
        WHERE a.archive_reason = $1
        """,
        [AwxProxmoxUnmerge.archive_reason()]
      )

    Enum.map(rows, fn [id, device_id, value] ->
      %{archive_id: id, device_uid: device_id, mac: value}
    end)
  end

  defp unasserted([]), do: []

  defp unasserted(pairs) do
    %{rows: rows} =
      query!(
        """
        SELECT device_a, device_b FROM platform.identity_distinct_assertions
        WHERE device_a = ANY($1::text[]) OR device_b = ANY($1::text[])
        """,
        [Enum.flat_map(pairs, &[&1.merged, &1.survivor])]
      )

    asserted = MapSet.new(rows, fn [a, b] -> {a, b} end)

    for pair <- pairs,
        not MapSet.member?(asserted, Enum.min_max([pair.merged, pair.survivor])),
        do: %{event_id: pair.event_id, merged: pair.merged, survivor: pair.survivor}
  end

  # Every AWX controller, and every guest the unmerged merges bound, observed since the repair.
  defp settled?(_pairs, nil), do: false

  defp settled?(pairs, finished) do
    %{rows: [[awx]]} =
      query!("SELECT min(observed_at) FROM platform.ansible_awx_inventory_observations", [])

    %{rows: [[guests]]} =
      query!(
        """
        SELECT min(g.observed_at)
        FROM platform.virtualization_guests g
        JOIN platform.merge_audit m ON m.details->>'guest_provider_ref' = g.provider_ref
        WHERE m.event_id::text = ANY($1::text[])
        """,
        [Enum.map(pairs, & &1.event_id)]
      )

    Enum.all?([awx, guests], fn at -> is_nil(at) or DateTime.after?(utc(at), finished) end) and
      not is_nil(awx)
  end

  defp utc_or_nil(nil), do: nil
  defp utc_or_nil(at), do: utc(at)

  defp utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
  defp utc(%DateTime{} = at), do: at

  defp query!(sql, params), do: Ecto.Adapters.SQL.query!(Repo, sql, params)
end
