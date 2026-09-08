defmodule ServiceRadar.Inventory.Identity.Reassignments do
  @moduledoc """
  Bulk reassignment of device-linked records (identifiers, service
  checks, alerts, agents, alias states, interfaces) to a canonical
  device during merges.
  """

  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.DeviceSourceObservation
  alias ServiceRadar.Inventory.Identity.AgentAnchor
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Monitoring.ServiceCheck

  require Ash.Query
  require Logger

  def reassign_device_identifiers(from_id, to_id, actor) do
    bulk_reassign(
      DeviceIdentifier,
      :reassign_device,
      :device_id,
      from_id,
      %{device_id: to_id},
      actor
    )
  end

  def reassign_service_checks(from_id, to_id, actor) do
    bulk_reassign(
      ServiceCheck,
      :reassign_device,
      :device_uid,
      from_id,
      %{device_uid: to_id},
      actor
    )
  end

  def reassign_source_observations(from_id, to_id, actor) do
    bulk_reassign(
      DeviceSourceObservation,
      :reassign_device,
      :device_id,
      from_id,
      %{device_id: to_id},
      actor
    )
  end

  def reassign_alerts(from_id, to_id, actor) do
    bulk_reassign(Alert, :reassign_device, :device_uid, from_id, %{device_uid: to_id}, actor)
  end

  @doc """
  Repoint agent rows from a merged-away device onto the survivor — but never
  move an agent onto a survivor that contradicts its stable behavioral anchor
  (DIRE prevent-at-source).

  A merge that slipped past the alias/merge guards must not be allowed to weld
  an agent to a foreign host: if the survivor is reciprocally owned by a
  DIFFERENT agent while this agent has its own distinct anchor device, the move
  is refused (the agent is left on its anchored device) and
  `[:serviceradar, :identity_reconciler, :agent_link, :reassign_blocked]` is
  emitted. Default behavior is unchanged — agents without a conflicting anchor
  are reassigned exactly as before.
  """
  def reassign_agents(from_id, to_id, actor) do
    base_query = Ash.Query.for_read(Agent, :read, %{}, actor: actor)
    query = Ash.Query.filter(base_query, device_uid == ^from_id)

    case Ash.read(query, actor: actor) do
      {:ok, []} ->
        :ok

      {:ok, agents} ->
        {to_move, blocked} =
          Enum.split_with(agents, fn agent ->
            not AgentAnchor.conflicts_with_anchor?(agent.uid, to_id, actor)
          end)

        Enum.each(blocked, fn agent ->
          Logger.warning(
            "Reassignments: refusing to repoint agent #{agent.uid} onto #{to_id} " <>
              "during merge of #{from_id} -> #{to_id}: survivor conflicts with the " <>
              "agent's behavioral anchor"
          )

          :telemetry.execute(
            [:serviceradar, :identity_reconciler, :agent_link, :reassign_blocked],
            %{count: 1},
            %{agent_uid: agent.uid, from_device_id: from_id, to_device_id: to_id}
          )
        end)

        reassign_records(to_move, %{device_uid: to_id}, actor)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Repoint per-agent availability rows to the canonical device. A row whose
  (device, agent) pair already exists on the survivor is dropped instead of
  violating the unique identity.
  """
  def reassign_availability(from_id, to_id, actor) do
    case DeviceAgentAvailability.list_by_device(from_id, actor: actor) do
      {:ok, rows} ->
        Enum.reduce_while(rows, :ok, fn row, :ok ->
          case DeviceAgentAvailability.get_by_device_agent(to_id, row.agent_id, actor: actor) do
            {:ok, %DeviceAgentAvailability{}} ->
              case Ash.destroy(row, actor: actor) do
                :ok -> {:cont, :ok}
                {:error, error} -> {:halt, {:error, error}}
              end

            _ ->
              row
              |> Ash.Changeset.for_update(:reassign_device, %{device_uid: to_id})
              |> Ash.update(actor: actor)
              |> case do
                {:ok, _} -> {:cont, :ok}
                {:error, error} -> {:halt, {:error, error}}
              end
          end
        end)

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Repoint composite check verdicts to the canonical device. A row whose
  (device, check) pair already exists on the survivor is dropped instead of
  violating the unique identity — the survivor's own verdict is the current one.

  Without this, every verdict strands on the losing UID after a merge and the
  device silently loses its compliance state.
  """
  def reassign_composite_results(from_id, to_id, actor) do
    case DeviceCompositeCheckResult.list_by_device(from_id, actor: actor) do
      {:ok, rows} ->
        Enum.reduce_while(rows, :ok, fn row, :ok ->
          case DeviceCompositeCheckResult.get_by_device_check(to_id, row.check_id, actor: actor) do
            {:ok, %DeviceCompositeCheckResult{}} ->
              case Ash.destroy(row, actor: actor) do
                :ok -> {:cont, :ok}
                {:error, error} -> {:halt, {:error, error}}
              end

            _ ->
              row
              |> Ash.Changeset.for_update(:reassign_device, %{device_uid: to_id})
              |> Ash.update(actor: actor)
              |> case do
                {:ok, _} -> {:cont, :ok}
                {:error, error} -> {:halt, {:error, error}}
              end
          end
        end)

      {:error, error} ->
        {:error, error}
    end
  end

  def reassign_alias_states(from_id, to_id, actor) do
    bulk_reassign(
      DeviceAliasState,
      :reassign_device,
      :device_id,
      from_id,
      %{device_id: to_id},
      actor
    )
  end

  def reassign_interfaces(from_id, to_id, actor) do
    query =
      Interface
      |> Ash.Query.filter(device_id == ^from_id)
      |> Ash.Query.for_read(:read, %{}, actor: actor)

    case Ash.read(query, actor: actor) do
      {:ok, []} ->
        :ok

      {:ok, records} ->
        interface_uids = records |> Enum.map(& &1.interface_uid) |> Enum.uniq()

        with {:ok, existing_keys} <-
               fetch_existing_interface_keys(to_id, interface_uids, actor) do
          {to_update, to_delete} =
            Enum.split_with(records, fn record ->
              not existing_interface_key?(existing_keys, record)
            end)

          with :ok <- bulk_update_interfaces(to_update, to_id, actor) do
            bulk_delete_interfaces(to_delete, actor)
          end
        end

      {:error, _} = error ->
        error
    end
  end

  defp fetch_existing_interface_keys(_to_id, [], _actor), do: {:ok, []}

  defp fetch_existing_interface_keys(to_id, interface_uids, actor) do
    existing_query =
      Interface
      |> Ash.Query.filter(device_id == ^to_id and interface_uid in ^interface_uids)
      |> Ash.Query.for_read(:read, %{}, actor: actor)

    case Ash.read(existing_query, actor: actor) do
      {:ok, existing} ->
        existing
        |> Enum.map(& &1.interface_uid)
        |> then(&{:ok, &1})

      {:error, _} = error ->
        error
    end
  end

  defp bulk_update_interfaces([], _to_id, _actor), do: :ok

  defp bulk_update_interfaces(records, to_id, actor) do
    records
    |> Ash.bulk_update(:reassign_device, %{device_id: to_id}, actor: actor)
    |> normalize_bulk_result()
  end

  defp bulk_delete_interfaces([], _actor), do: :ok

  defp bulk_delete_interfaces(records, actor) do
    records
    |> Ash.bulk_destroy(:destroy, %{}, actor: actor)
    |> normalize_bulk_result()
  end

  defp bulk_reassign(resource, action, filter_field, filter_value, attrs, actor) do
    base_query = Ash.Query.for_read(resource, :read, %{}, actor: actor)

    query =
      case filter_field do
        :device_id -> Ash.Query.filter(base_query, device_id == ^filter_value)
        :device_uid -> Ash.Query.filter(base_query, device_uid == ^filter_value)
      end

    case Ash.read(query, actor: actor) do
      {:ok, []} ->
        :ok

      {:ok, records} ->
        records
        |> Ash.bulk_update(action, attrs, actor: actor)
        |> normalize_bulk_result()

      {:error, _} = error ->
        error
    end
  end

  # Bulk-reassign an already-loaded list of records (used by the anchor-aware
  # agent reassignment, which must filter records before updating).
  defp reassign_records([], _attrs, _actor), do: :ok

  defp reassign_records(records, attrs, actor) do
    records
    |> Ash.bulk_update(:reassign_device, attrs, actor: actor)
    |> normalize_bulk_result()
  end

  defp normalize_bulk_result(result) do
    case result do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{} = bulk_result -> {:error, bulk_result}
    end
  end

  defp existing_interface_key?(existing_keys, record) when is_list(existing_keys) do
    Enum.member?(existing_keys, record.interface_uid)
  end
end
