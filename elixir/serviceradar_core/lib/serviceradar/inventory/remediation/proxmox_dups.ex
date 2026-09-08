defmodule ServiceRadar.Inventory.Remediation.ProxmoxDups do
  @moduledoc """
  Step `proxmox-dups` (OpenSpec refactor-device-identity-reconciliation 4.4).

  Collapses intra-Proxmox duplicate device rows created by `integration_id`
  format churn and multi-homed Proxmox hosts: live devices whose
  `discovery_sources` include `proxmox` or whose metadata marks
  `proxmox_candidate=true` are grouped by normalized hostname, then each
  hostname group is split into identity components
  (`Decisions.identity_components/1`) — devices corroborated as the SAME physical
  host by a shared MAC or Proxmox host reference. Only within a component of two
  or more devices are the non-canonical rows merged into the canonical one via
  `IdentityReconciler.merge_devices/3`.

  Hostname alone is NEVER a merge key. Distinct Proxmox clusters routinely reuse
  node hostnames (`pve01`, `pve02`, …), so two same-hostname rows from different
  clusters — with no shared MAC and no shared enrichment reference — are distinct
  hardware and are left untouched (counted as `skipped_unrelated`). Multi-homed
  rows of one host (sharing its node reference) and `integration_id`-churn rows
  (sharing a `legacy_integration_ids` token) still collapse.

  Canonical selection (see `Decisions.select_canonical/2`): an agent-linked
  device wins, then the most recently seen, then lowest uid. A duplicate that
  an actively-connected agent links to is never merged away (skipped with a
  warning).

  Merges use reason `"proxmox_dedupe"` (NOT a `"manual"` reason). This is
  deliberate: a non-manual reason keeps the merge engine's identity guards
  (distinct-agent veto, provisional-topology / distinct-MAC veto, per-pair
  cooldown) ENGAGED as defense-in-depth, on top of this step's own
  same-physical-host corroboration requirement. Each merge is fully audited by
  the merge engine; the manifest records every from->to pair.
  """

  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.Remediation.Decisions
  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Repo

  require Logger

  @step "proxmox-dups"
  @merge_reason "proxmox_dedupe"

  @doc false
  def run(mode, opts, manifest, actor) do
    source = Keyword.get(opts, :proxmox_source, "proxmox")
    denylist = Keyword.get(opts, :hostname_denylist, Decisions.default_hostname_denylist())

    devices = proxmox_devices(source)
    linked = linked_device_uids()
    protected = actively_linked_device_uids()

    groups = Decisions.duplicate_hostname_groups(devices, denylist)

    {merges, skipped, skipped_unrelated} = plan_merges(groups, linked, protected)

    base = %{
      proxmox_devices: length(devices),
      duplicate_groups: length(groups),
      planned_merges: length(merges),
      skipped_protected: skipped,
      skipped_unrelated: skipped_unrelated,
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
        SELECT d.uid, d.hostname, d.last_seen_time,
          COALESCE(mac.macs, '{}') AS macs,
          (
            COALESCE(
              ARRAY(
                SELECT jsonb_array_elements_text(d.metadata->'legacy_integration_ids')
                WHERE jsonb_typeof(d.metadata->'legacy_integration_ids') = 'array'
              ),
              '{}'
            )
            || ARRAY_REMOVE(
                 ARRAY[
                   NULLIF(btrim(d.metadata->>'integration_id'), ''),
                   NULLIF(btrim(d.metadata->>'hypervisor_provider_ref'), ''),
                   NULLIF(btrim(d.metadata->>'hypervisor_host_provider_ref'), '')
                 ],
                 NULL
               )
          ) AS host_refs
        FROM platform.ocsf_devices d
        LEFT JOIN LATERAL (
          SELECT array_agg(DISTINCT upper(btrim(di.identifier_value))) AS macs
          FROM platform.device_identifiers di
          WHERE di.device_id = d.uid
            AND di.identifier_type = 'mac'
            AND btrim(COALESCE(di.identifier_value, '')) <> ''
        ) mac ON true
        WHERE d.deleted_at IS NULL
          AND (
            COALESCE($1 = ANY(d.discovery_sources), false)
            OR lower(COALESCE(d.metadata->>'proxmox_candidate', '')) IN ('true', '1', 'yes')
          )
          AND d.hostname IS NOT NULL
          AND btrim(d.hostname) <> ''
        ORDER BY d.uid
        """,
        [source]
      )

    Enum.map(rows, fn [uid, hostname, last_seen, macs, host_refs] ->
      %{
        uid: uid,
        hostname: hostname,
        last_seen_time: to_datetime(last_seen),
        macs: token_set(macs),
        host_refs: token_set(host_refs)
      }
    end)
  end

  defp token_set(values) when is_list(values) do
    values
    |> Enum.map(fn v -> v |> to_string() |> String.trim() end)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp token_set(_), do: MapSet.new()

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
    |> Enum.reduce({[], 0, 0}, fn {hostname, group}, acc ->
      group
      |> Decisions.identity_components()
      |> Enum.reduce(acc, &plan_component(&1, hostname, linked, protected, &2))
    end)
    |> then(fn {merges, skipped, unrelated} -> {Enum.reverse(merges), skipped, unrelated} end)
  end

  # A device that shares a hostname with others but has no same-physical-host
  # peer (no shared MAC / Proxmox host reference) is a distinct host — never
  # merged; only tallied so operators can see how many hostname collisions were
  # deliberately left intact (e.g. `pve02` in two different clusters).
  defp plan_component([_single], _hostname, _linked, _protected, {merges, skipped, unrelated}),
    do: {merges, skipped, unrelated + 1}

  defp plan_component(component, hostname, linked, protected, acc) do
    canonical = Decisions.select_canonical(component, linked)

    component
    |> Enum.reject(&(&1.uid == canonical.uid))
    |> Enum.reduce(acc, fn duplicate, {merges, skipped, unrelated} ->
      if MapSet.member?(protected, duplicate.uid) do
        Logger.warning(
          "ProxmoxDups: refusing to merge away #{duplicate.uid} (#{hostname}) — " <>
            "an active agent links to it"
        )

        {merges, skipped + 1, unrelated}
      else
        {[{hostname, duplicate.uid, canonical.uid} | merges], skipped, unrelated}
      end
    end)
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
