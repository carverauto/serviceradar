defmodule ServiceRadar.Inventory.Remediation.TestDebris do
  @moduledoc """
  Step `test-debris` (OpenSpec refactor-device-identity-reconciliation 4.2).

  Removes 2026-04-25 test-suite debris:

  * `ocsf_agents` rows matched by `Decisions.debris_agent?/2` (conservative:
    configurable uid prefixes + created on the debris date + not in an active
    connection state; the "named" patterns additionally require a NULL
    `device_uid`). Rows are hard-deleted (uids recorded in the manifest).
  * reip-simulation devices (`agent_id` prefix `agent-reip-`, hostnames
    k8s-pod-a/k8s-pod-b): their `device_identifiers` and
    `device_alias_states` rows are hard-deleted and the device rows are
    soft-deleted (audited, reversible) with reason
    `"dire_remediation_test_debris"`. Devices currently linked from any
    active agent are never touched.
  * any stray `agent_id` identifiers naming a deleted debris agent.
  """

  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Remediation.Decisions
  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @step "test-debris"

  @doc false
  def run(mode, opts, manifest, actor) do
    debris_agents = find_debris_agents(opts, actor)
    debris_agent_uids = Enum.map(debris_agents, & &1.uid)
    debris_devices = find_debris_devices(opts)
    debris_device_uids = Enum.map(debris_devices, fn {uid, _hostname, _agent_id} -> uid end)

    base = %{
      debris_agents: length(debris_agent_uids),
      debris_agent_uids: Enum.sort(debris_agent_uids),
      debris_devices: length(debris_device_uids),
      debris_device_uids: Enum.sort(debris_device_uids)
    }

    case mode do
      :dry_run ->
        Map.merge(base, %{
          would_delete_identifiers: count_device_identifiers(debris_device_uids),
          would_delete_alias_states: count_alias_states(debris_device_uids),
          would_delete_agent_identifiers: count_agent_identifiers(debris_agent_uids)
        })

      :execute ->
        identifier_ids = delete_device_identifiers(debris_device_uids, manifest)
        alias_ids = delete_alias_states(debris_device_uids, manifest)
        agent_identifier_ids = delete_agent_identifiers(debris_agent_uids, manifest)
        soft_deleted = soft_delete_devices(debris_device_uids, manifest, actor)
        deleted_agents = delete_agents(debris_agent_uids, manifest)

        Map.merge(base, %{
          deleted_agents: deleted_agents,
          deleted_identifiers: length(identifier_ids),
          deleted_alias_states: length(alias_ids),
          deleted_agent_identifiers: length(agent_identifier_ids),
          soft_deleted_devices: soft_deleted
        })
    end
  end

  # -- selection ---------------------------------------------------------------

  defp find_debris_agents(opts, actor) do
    decision_opts = [
      date: Keyword.get(opts, :debris_date, Decisions.default_debris_date()),
      null_device_patterns:
        Keyword.get(opts, :debris_null_patterns, Decisions.default_null_device_patterns()),
      sim_patterns: Keyword.get(opts, :debris_sim_patterns, Decisions.default_sim_patterns())
    ]

    Agent
    |> Ash.read!(actor: actor)
    |> Enum.filter(&Decisions.debris_agent?(&1, decision_opts))
  end

  # Debris devices, excluding anything an active agent links to (paranoia:
  # debris must never take a live agent's device with it).
  defp find_debris_devices(opts) do
    prefix =
      Keyword.get(
        opts,
        :debris_device_agent_prefix,
        Decisions.default_debris_device_agent_prefix()
      )

    hostnames = Keyword.get(opts, :debris_hostnames, Decisions.default_debris_hostnames())

    %{rows: rows} =
      query!(
        """
        SELECT uid, hostname, agent_id
        FROM platform.ocsf_devices
        WHERE deleted_at IS NULL
          AND (agent_id LIKE $1 OR lower(btrim(hostname)) = ANY($2))
          AND uid NOT IN (
            SELECT device_uid FROM platform.ocsf_agents
            WHERE device_uid IS NOT NULL
              AND status IN ('connected', 'connecting', 'degraded')
          )
        ORDER BY uid
        """,
        [prefix <> "%", Enum.map(hostnames, &String.downcase/1)]
      )

    rows
    |> Enum.map(fn [uid, hostname, agent_id] -> {uid, hostname, agent_id} end)
    |> Enum.filter(fn {_uid, hostname, agent_id} ->
      Decisions.debris_device?(%{hostname: hostname, agent_id: agent_id},
        agent_id_prefix: prefix,
        hostnames: hostnames
      )
    end)
  end

  # -- counts (dry run) ---------------------------------------------------------

  defp count_device_identifiers([]), do: 0

  defp count_device_identifiers(device_uids) do
    %{rows: [[count]]} =
      query!(
        "SELECT count(*) FROM platform.device_identifiers WHERE device_id = ANY($1)",
        [device_uids]
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

  defp count_agent_identifiers([]), do: 0

  defp count_agent_identifiers(agent_uids) do
    %{rows: [[count]]} =
      query!(
        "SELECT count(*) FROM platform.device_identifiers " <>
          "WHERE identifier_type = 'agent_id' AND identifier_value = ANY($1)",
        [agent_uids]
      )

    count
  end

  # -- execution ----------------------------------------------------------------

  defp delete_device_identifiers([], _manifest), do: []

  defp delete_device_identifiers(device_uids, manifest) do
    %{rows: rows} =
      query!(
        "DELETE FROM platform.device_identifiers WHERE device_id = ANY($1) RETURNING id",
        [device_uids]
      )

    ids = List.flatten(rows)

    Manifest.record(
      manifest,
      @step,
      :delete_device_identifiers,
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

  defp delete_agent_identifiers([], _manifest), do: []

  defp delete_agent_identifiers(agent_uids, manifest) do
    %{rows: rows} =
      query!(
        "DELETE FROM platform.device_identifiers " <>
          "WHERE identifier_type = 'agent_id' AND identifier_value = ANY($1) RETURNING id",
        [agent_uids]
      )

    ids = List.flatten(rows)

    Manifest.record(
      manifest,
      @step,
      :delete_agent_identifiers,
      "platform.device_identifiers",
      ids
    )

    ids
  end

  defp soft_delete_devices(device_uids, manifest, actor) do
    deleted =
      Enum.reduce(device_uids, [], fn uid, acc ->
        case Device.get_by_uid(uid, false, actor: actor) do
          {:ok, %Device{} = device} ->
            case Device.soft_delete(device, "dire_remediation_test_debris", "dire_remediation",
                   actor: actor
                 ) do
              {:ok, _} ->
                [uid | acc]

              {:error, error} ->
                Logger.warning("TestDebris: failed to soft-delete #{uid}: #{inspect(error)}")
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
