defmodule ServiceRadar.FlowAttribution.WorkloadBackfill do
  @moduledoc false

  @schema "platform"
  @table "flow_process_attribution_current"
  @workload_identity_table "workload_identity_current"
  @correlation_window_minutes 15
  @correlation_skew_seconds 900

  @backfill_current_workload_sql """
  WITH updated_rows AS (
    UPDATE #{@schema}.#{@table} AS attr
    SET
      workload_identity = NULLIF(
        COALESCE(workload.identity, '{}'::jsonb) || COALESCE(attr.workload_identity, '{}'::jsonb),
        '{}'::jsonb
      ),
      updated_at = now()
    FROM #{@schema}.#{@workload_identity_table} AS workload
    WHERE attr.container_id IS NOT NULL
      AND attr.container_id <> ''
      AND attr.observed_at > now() - interval '#{@correlation_window_minutes * 60 + @correlation_skew_seconds} seconds'
      AND workload.partition = attr.partition
      AND workload.agent_id = attr.agent_id
      AND workload.container_id = attr.container_id
      AND (
        attr.workload_identity IS NULL
        OR NOT (attr.workload_identity ? 'context_name')
      )
      AND COALESCE(attr.workload_identity, '{}'::jsonb) <>
        (
          COALESCE(workload.identity, '{}'::jsonb) ||
            COALESCE(attr.workload_identity, '{}'::jsonb)
        )
    RETURNING 1
  )
  SELECT count(*) FROM updated_rows
  """

  @backfill_current_workload_for_keys_sql """
  WITH input_keys AS (
    SELECT DISTINCT
      r.partition,
      r.agent_id,
      r.container_id
    FROM jsonb_to_recordset(($1::text)::jsonb) AS r(
      partition text,
      agent_id text,
      container_id text
    )
    WHERE r.partition IS NOT NULL
      AND r.agent_id IS NOT NULL
      AND r.container_id IS NOT NULL
      AND r.container_id <> ''
  ),
  updated_rows AS (
    UPDATE #{@schema}.#{@table} AS attr
    SET
      workload_identity = NULLIF(
        COALESCE(workload.identity, '{}'::jsonb) || COALESCE(attr.workload_identity, '{}'::jsonb),
        '{}'::jsonb
      ),
      updated_at = now()
    FROM input_keys AS keys
    JOIN #{@schema}.#{@workload_identity_table} AS workload
      ON workload.partition = keys.partition
     AND workload.agent_id = keys.agent_id
     AND workload.container_id = keys.container_id
    WHERE attr.container_id IS NOT NULL
      AND attr.container_id <> ''
      AND attr.observed_at > now() - interval '#{@correlation_window_minutes * 60 + @correlation_skew_seconds} seconds'
      AND attr.partition = keys.partition
      AND attr.agent_id = keys.agent_id
      AND attr.container_id = keys.container_id
      AND (
        attr.workload_identity IS NULL
        OR NOT (attr.workload_identity ? 'context_name')
      )
      AND COALESCE(attr.workload_identity, '{}'::jsonb) <>
        (
          COALESCE(workload.identity, '{}'::jsonb) ||
            COALESCE(attr.workload_identity, '{}'::jsonb)
        )
    RETURNING 1
  )
  SELECT count(*) FROM updated_rows
  """

  @spec backfill_current_workload_identity() :: {:ok, non_neg_integer()} | {:error, term()}
  def backfill_current_workload_identity do
    case ServiceRadar.Repo.query(@backfill_current_workload_sql, []) do
      {:ok, %{rows: [[num_rows]]}} -> {:ok, num_rows}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec backfill_current_workload_identity([map()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def backfill_current_workload_identity(rows) when is_list(rows) do
    keys =
      rows
      |> Enum.map(&workload_backfill_key/1)
      |> Enum.reject(&is_nil/1)

    if keys == [] do
      {:ok, 0}
    else
      case ServiceRadar.Repo.query(@backfill_current_workload_for_keys_sql, [Jason.encode!(keys)]) do
        {:ok, %{rows: [[num_rows]]}} -> {:ok, num_rows}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def backfill_current_workload_identity(_rows), do: {:ok, 0}

  defp workload_backfill_key(row) when is_map(row) do
    partition = Map.get(row, :partition) || Map.get(row, "partition")
    agent_id = Map.get(row, :agent_id) || Map.get(row, "agent_id")
    container_id = Map.get(row, :container_id) || Map.get(row, "container_id")

    if partition in [nil, ""] or agent_id in [nil, ""] or container_id in [nil, ""] do
      nil
    else
      %{
        partition: partition,
        agent_id: agent_id,
        container_id: container_id
      }
    end
  end

  defp workload_backfill_key(_row), do: nil
end
