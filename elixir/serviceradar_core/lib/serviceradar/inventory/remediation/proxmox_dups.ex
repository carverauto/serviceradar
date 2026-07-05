defmodule ServiceRadar.Inventory.Remediation.ProxmoxDups do
  @moduledoc """
  Step `proxmox-dups` (OpenSpec refactor-device-identity-reconciliation 4.4).

  Collapses intra-Proxmox duplicate device rows created by `integration_id`
  format churn and multi-homed Proxmox discovery candidates: live devices whose
  `discovery_sources` include `proxmox` or whose metadata marks
  `proxmox_candidate=true` are grouped by normalized hostname; in every group
  with more than one device, the non-canonical rows are merged into the
  canonical one via `IdentityReconciler.merge_devices/3`.

  Canonical selection (see `Decisions.select_canonical/2`): an agent-linked
  device wins, then the most recently seen, then lowest uid. A duplicate that
  an actively-connected agent links to is never merged away (skipped with a
  warning).

  Merges use reason `"manual_remediation"`. This is deliberate: the merge
  guards added in phase 1 (distinct-agent veto + per-pair cooldown) are
  bypassed for reasons starting with `"manual"` — verified against
  `Identity.MergeEngine.manual_override_merge_reason?/1`
  (`String.starts_with?(reason, "manual")`) — because this is an
  operator-invoked administrative merge. Each merge is fully audited by the
  merge engine itself; the manifest records every from->to pair.
  """

  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.Remediation.Decisions
  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Repo

  require Logger

  @step "proxmox-dups"
  @merge_reason "manual_remediation"

  @doc false
  def run(mode, opts, manifest, actor) do
    source = Keyword.get(opts, :proxmox_source, "proxmox")
    denylist = Keyword.get(opts, :hostname_denylist, Decisions.default_hostname_denylist())

    devices = proxmox_devices(source)
    linked = linked_device_uids()
    protected = actively_linked_device_uids()

    groups = Decisions.duplicate_hostname_groups(devices, denylist)

    {merges, skipped} = plan_merges(groups, linked, protected)

    base = %{
      proxmox_devices: length(devices),
      duplicate_groups: length(groups),
      planned_merges: length(merges),
      skipped_protected: skipped,
      merge_plan:
        Enum.map(merges, fn {hostname, from, to} ->
          %{hostname: hostname, from: from, to: to}
        end)
    }

    case mode do
      :dry_run ->
        base

      :execute ->
        {merged, failed} = execute_merges(merges, manifest, actor)
        Map.merge(base, %{merged: merged, merge_failures: failed})
    end
  end

  defp proxmox_devices(source) do
    %{rows: rows} =
      query!(
        """
        SELECT uid, hostname, last_seen_time
        FROM platform.ocsf_devices
        WHERE deleted_at IS NULL
          AND (
            COALESCE($1 = ANY(discovery_sources), false)
            OR lower(COALESCE(metadata->>'proxmox_candidate', '')) IN ('true', '1', 'yes')
          )
          AND hostname IS NOT NULL
          AND btrim(hostname) <> ''
        ORDER BY uid
        """,
        [source]
      )

    Enum.map(rows, fn [uid, hostname, last_seen] ->
      %{uid: uid, hostname: hostname, last_seen_time: to_datetime(last_seen)}
    end)
  end

  defp linked_device_uids do
    %{rows: rows} =
      query!(
        "SELECT DISTINCT device_uid FROM platform.ocsf_agents WHERE device_uid IS NOT NULL",
        []
      )

    rows |> List.flatten() |> MapSet.new()
  end

  defp actively_linked_device_uids do
    %{rows: rows} =
      query!(
        "SELECT DISTINCT device_uid FROM platform.ocsf_agents " <>
          "WHERE device_uid IS NOT NULL AND status IN ('connected', 'connecting', 'degraded')",
        []
      )

    rows |> List.flatten() |> MapSet.new()
  end

  defp plan_merges(groups, linked, protected) do
    groups
    |> Enum.reduce({[], 0}, fn {hostname, group}, {merges, skipped} ->
      canonical = Decisions.select_canonical(group, linked)

      group
      |> Enum.reject(&(&1.uid == canonical.uid))
      |> Enum.reduce({merges, skipped}, fn duplicate, {merges, skipped} ->
        if MapSet.member?(protected, duplicate.uid) do
          Logger.warning(
            "ProxmoxDups: refusing to merge away #{duplicate.uid} (#{hostname}) — " <>
              "an active agent links to it"
          )

          {merges, skipped + 1}
        else
          {[{hostname, duplicate.uid, canonical.uid} | merges], skipped}
        end
      end)
    end)
    |> then(fn {merges, skipped} -> {Enum.reverse(merges), skipped} end)
  end

  defp execute_merges(merges, manifest, actor) do
    Enum.reduce(merges, {0, 0}, fn {hostname, from, to}, {merged, failed} ->
      case IdentityReconciler.merge_devices(from, to,
             actor: actor,
             reason: @merge_reason,
             details: %{
               step: @step,
               source: "dire_remediation",
               hostname: hostname
             }
           ) do
        :ok ->
          Manifest.record(manifest, @step, :merge_device, "platform.ocsf_devices", [from], %{
            into: to,
            hostname: hostname,
            reason: @merge_reason
          })

          {merged + 1, failed}

        {:error, error} ->
          Logger.warning(
            "ProxmoxDups: merge #{from} -> #{to} (#{hostname}) failed: #{inspect(error)}"
          )

          {merged, failed + 1}
      end
    end)
  end

  defp to_datetime(%DateTime{} = dt), do: dt
  defp to_datetime(%NaiveDateTime{} = dt), do: DateTime.from_naive!(dt, "Etc/UTC")
  defp to_datetime(_), do: nil

  defp query!(sql, params), do: Ecto.Adapters.SQL.query!(Repo, sql, params)
end
