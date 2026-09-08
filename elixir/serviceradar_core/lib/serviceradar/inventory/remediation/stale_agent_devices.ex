defmodule ServiceRadar.Inventory.Remediation.StaleAgentDevices do
  @moduledoc """
  Step `stale-agent-devices`.

  Reaps unavailable historical agent rows created by agent UID churn and cleans
  their device identity residue. Devices directly owned by a stale agent are
  soft-deleted only when no active agent links to that device. Shared canonical
  devices are preserved; stale `agent_id` identifiers on them are removed.
  """

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Repo

  require Logger

  @step "stale-agent-devices"
  @default_agent_uids ["agent-dusk", "agent-agent-dusk"]
  @default_agent_prefixes ["agent-dusk-", "agent-agent-dusk-", "agent-dusk01-"]
  @default_before ~U[2026-05-01 00:00:00Z]
  @active_statuses ["connected", "connecting", "degraded"]

  @doc false
  def run(mode, opts, manifest, actor) do
    stale_agent_uids = stale_agent_uids(opts)
    stale_device_uids = stale_device_uids(stale_agent_uids)

    base = %{
      stale_agents: length(stale_agent_uids),
      stale_agent_uids: stale_agent_uids,
      stale_devices: length(stale_device_uids),
      stale_device_uids: stale_device_uids
    }

    case mode do
      :dry_run ->
        Map.merge(base, %{
          would_delete_identifiers: count_stale_identifiers(stale_agent_uids, stale_device_uids),
          would_delete_alias_states: count_alias_states(stale_device_uids)
        })

      :execute ->
        identifier_ids = delete_stale_identifiers(stale_agent_uids, stale_device_uids, manifest)
        alias_ids = delete_alias_states(stale_device_uids, manifest)
        soft_deleted = soft_delete_devices(stale_device_uids, manifest, actor)
        deleted_agents = delete_agents(stale_agent_uids, manifest)

        Map.merge(base, %{
          deleted_agents: deleted_agents,
          deleted_identifiers: length(identifier_ids),
          deleted_alias_states: length(alias_ids),
          soft_deleted_devices: soft_deleted
        })
    end
  end

  defp stale_agent_uids(opts) do
    exact = Keyword.get(opts, :stale_agent_uids, @default_agent_uids)
    prefixes = Keyword.get(opts, :stale_agent_prefixes, @default_agent_prefixes)
    before = Keyword.get(opts, :stale_agent_before, @default_before)
    like_patterns = Enum.map(prefixes, &(&1 <> "%"))

    %{rows: rows} =
      query!(
        """
        SELECT uid
        FROM platform.ocsf_agents
        WHERE status = 'unavailable'
          AND (last_seen_time IS NULL OR last_seen_time < $1)
          AND (uid = ANY($2) OR uid LIKE ANY($3))
        ORDER BY uid
        """,
        [before, exact, like_patterns]
      )

    List.flatten(rows)
  end

  defp stale_device_uids([]), do: []

  defp stale_device_uids(agent_uids) do
    %{rows: rows} =
      query!(
        """
        SELECT DISTINCT d.uid
        FROM platform.ocsf_devices d
        WHERE d.deleted_at IS NULL
          AND d.agent_id = ANY($1)
          AND NOT EXISTS (
            SELECT 1
            FROM platform.ocsf_agents a
            WHERE a.device_uid = d.uid
              AND a.status = ANY($2)
          )
        ORDER BY d.uid
        """,
        [agent_uids, @active_statuses]
      )

    List.flatten(rows)
  end

  defp count_stale_identifiers([], []), do: 0

  defp count_stale_identifiers(agent_uids, device_uids) do
    %{rows: [[count]]} =
      query!(
        """
        SELECT count(*)
        FROM platform.device_identifiers
        WHERE device_id = ANY($1)
           OR (identifier_type = 'agent_id' AND identifier_value = ANY($2))
        """,
        [device_uids, agent_uids]
      )

    count
  end

  defp count_alias_states([]), do: 0

  defp count_alias_states(device_uids) do
    %{rows: [[count]]} =
      query!(
        "SELECT count(*) FROM platform.device_alias_states WHERE device_id = ANY($1)",
        [device_uids]
      )

    count
  end

  defp delete_stale_identifiers([], [], _manifest), do: []

  defp delete_stale_identifiers(agent_uids, device_uids, manifest) do
    %{rows: rows} =
      query!(
        """
        DELETE FROM platform.device_identifiers
        WHERE device_id = ANY($1)
           OR (identifier_type = 'agent_id' AND identifier_value = ANY($2))
        RETURNING id
        """,
        [device_uids, agent_uids]
      )

    ids = List.flatten(rows)

    Manifest.record(
      manifest,
      @step,
      :delete_stale_agent_identifiers,
      "platform.device_identifiers",
      ids
    )

    ids
  end

  defp delete_alias_states([], _manifest), do: []

  defp delete_alias_states(device_uids, manifest) do
    %{rows: rows} =
      query!(
        "DELETE FROM platform.device_alias_states WHERE device_id = ANY($1) RETURNING id::text",
        [device_uids]
      )

    ids = List.flatten(rows)
    Manifest.record(manifest, @step, :delete_alias_states, "platform.device_alias_states", ids)
    ids
  end

  defp soft_delete_devices(device_uids, manifest, actor) do
    deleted =
      Enum.reduce(device_uids, [], fn uid, acc ->
        case Device.get_by_uid(uid, false, actor: actor) do
          {:ok, %Device{} = device} ->
            case Device.soft_delete(device, "dire_remediation_stale_agent", "dire_remediation",
                   actor: actor
                 ) do
              {:ok, _} ->
                [uid | acc]

              {:error, error} ->
                Logger.warning(
                  "StaleAgentDevices: failed to soft-delete #{uid}: #{inspect(error)}"
                )

                acc
            end

          _ ->
            acc
        end
      end)

    Manifest.record(manifest, @step, :soft_delete_devices, "platform.ocsf_devices", deleted)
    length(deleted)
  end

  defp delete_agents([], _manifest), do: 0

  defp delete_agents(agent_uids, manifest) do
    %{rows: rows} =
      query!("DELETE FROM platform.ocsf_agents WHERE uid = ANY($1) RETURNING uid", [agent_uids])

    uids = List.flatten(rows)
    Manifest.record(manifest, @step, :delete_agents, "platform.ocsf_agents", uids)
    length(uids)
  end

  defp query!(sql, params), do: Ecto.Adapters.SQL.query!(Repo, sql, params)
end
