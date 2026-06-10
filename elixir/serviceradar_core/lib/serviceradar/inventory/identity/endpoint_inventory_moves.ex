defmodule ServiceRadar.Inventory.Identity.EndpointInventoryMoves do
  @moduledoc """
  Endpoint-inventory ownership moves during merges: fleet-ordinal
  allocation, device_uid reassignment, and NULL-device_uid backfill
  for agents that gained a canonical device.
  """

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Inventory.EndpointInventoryFleetOrdinal
  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Repo

  require Logger

  @endpoint_inventory_current_device_uid_tables [
    "endpoint_inventory_scans",
    "endpoint_inventory_artifacts",
    "endpoint_inventory_packages"
  ]

  @doc """
  Backfill endpoint inventory rows that were ingested before an agent had a
  canonical device UID.

  This is intentionally idempotent and only claims rows whose `device_uid` is
  still NULL for the reporting agent.
  """
  @spec backfill_endpoint_inventory_device_uid_for_agent(String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def backfill_endpoint_inventory_device_uid_for_agent(agent_id, device_uid, opts \\ [])

  def backfill_endpoint_inventory_device_uid_for_agent(agent_id, device_uid, opts)
      when is_binary(agent_id) and is_binary(device_uid) do
    repo = Keyword.get(opts, :repo, Repo)

    case repo.transaction(fn ->
           with :ok <- ensure_endpoint_inventory_survivor_ordinal(device_uid),
                :ok <-
                  backfill_endpoint_inventory_null_device_uid_rows(repo, [agent_id], device_uid) do
             :ok
           else
             {:error, reason} -> repo.rollback(reason)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def backfill_endpoint_inventory_device_uid_for_agent(_agent_id, _device_uid, _opts), do: :ok

  def reconcile_endpoint_inventory_device_identity(from_id, to_id) do
    with {:ok, agent_ids} <- endpoint_inventory_agent_ids_for_device(to_id),
         :ok <- ensure_endpoint_inventory_survivor_ordinal(to_id),
         :ok <- reassign_endpoint_inventory_device_uid_rows(from_id, to_id),
         :ok <- tombstone_endpoint_inventory_ordinal(from_id) do
      backfill_endpoint_inventory_null_device_uid_rows(Repo, agent_ids, to_id)
    end
  end

  def ensure_endpoint_inventory_survivor_ordinal(device_uid) do
    case EndpointInventoryFleetOrdinal.ensure_allocated(device_uid) do
      {:ok, _ordinal} -> :ok
      {:error, _} = error -> error
    end
  end

  defp endpoint_inventory_agent_ids_for_device(device_uid) do
    sql = """
    SELECT uid
    FROM platform.ocsf_agents
    WHERE device_uid = $1
    """

    case SQL.query(Repo, sql, [device_uid]) do
      {:ok, %{rows: rows}} ->
        agent_ids =
          rows
          |> Enum.map(fn [agent_id] -> agent_id end)
          |> Enum.filter(&Ids.present_id?/1)

        {:ok, agent_ids}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reassign_endpoint_inventory_device_uid_rows(from_id, to_id) do
    Enum.reduce_while(@endpoint_inventory_current_device_uid_tables, :ok, fn table, :ok ->
      sql = """
      UPDATE platform.#{table}
      SET device_uid = $2
      WHERE device_uid = $1
      """

      case SQL.query(Repo, sql, [from_id, to_id]) do
        {:ok, _result} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp tombstone_endpoint_inventory_ordinal(device_uid) do
    sql = """
    UPDATE platform.device_fleet_ordinals
    SET tombstoned = TRUE
    WHERE uid = $1
    """

    case SQL.query(Repo, sql, [device_uid]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def backfill_endpoint_inventory_null_device_uid_rows(_repo, [], _device_uid), do: :ok

  def backfill_endpoint_inventory_null_device_uid_rows(repo, agent_ids, device_uid)
      when is_list(agent_ids) do
    agent_ids = Enum.filter(agent_ids, &Ids.present_id?/1)

    Enum.reduce_while(@endpoint_inventory_current_device_uid_tables, :ok, fn table, :ok ->
      sql = """
      UPDATE platform.#{table}
      SET device_uid = $2
      WHERE agent_id = ANY($1)
        AND device_uid IS NULL
      """

      case SQL.query(repo, sql, [agent_ids, device_uid]) do
        {:ok, _result} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
