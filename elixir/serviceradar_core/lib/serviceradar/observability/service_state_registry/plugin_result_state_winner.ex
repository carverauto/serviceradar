defmodule ServiceRadar.Observability.ServiceStateRegistry.PluginResultStateWinner do
  @moduledoc false

  alias ServiceRadar.Observability.ServiceStateRegistry.PluginStateContract
  alias ServiceRadar.Observability.ServiceStateRegistry.Queries
  alias ServiceRadar.Repo

  @doc false
  def select(row) when is_map(row) do
    observed_at = PluginStateContract.snapshot_logical_observed_at(row)

    params = identity_params(row) ++ [observed_at]

    with {:ok, %{rows: [winner_row]}} <-
           Repo.query(Queries.plugin_status_winner_for_observation(), params),
         winner = status_from_row(winner_row),
         {:ok, existing} <- existing_state(row) do
      {:ok, preferred_snapshot(row, existing, winner)}
    else
      {:ok, %{rows: []}} -> {:error, :plugin_result_observation_winner_missing}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_plugin_result_observation_winner, other}}
    end
  end

  def select(_row), do: {:error, :invalid_plugin_result_state_row}

  @doc false
  def multiple_reported_payloads?(row) when is_map(row) do
    observed_at =
      row |> PluginStateContract.snapshot_logical_observed_at() |> DateTime.to_iso8601()

    case Repo.query(
           Queries.reported_payload_count_for_observation(),
           identity_params(row) ++ [observed_at]
         ) do
      {:ok, %{rows: [[count]]}} when is_integer(count) -> {:ok, count > 1}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_reported_payload_count, other}}
    end
  end

  def multiple_reported_payloads?(_row), do: {:ok, false}

  defp preferred_snapshot(incoming, existing, winner) do
    winner_digest = PluginStateContract.snapshot_payload_digest(winner)
    incoming_digest = PluginStateContract.snapshot_payload_digest(incoming)
    existing_digest = existing && PluginStateContract.snapshot_payload_digest(existing)
    winner_observed_at = logical_observed_at(winner)
    incoming_observed_at = logical_observed_at(incoming)
    existing_observed_at = existing && logical_observed_at(existing)

    selected =
      cond do
        winner_digest == incoming_digest and winner.available == incoming.available and
            winner_observed_at == incoming_observed_at ->
          incoming

        (existing && winner_digest == existing_digest) and
          winner.available == existing.available and
            winner_observed_at == existing_observed_at ->
          existing

        true ->
          winner
      end

    if existing &&
         not PluginStateContract.same_logical_observation?(existing, selected) &&
         PluginStateContract.compare_snapshots(existing, selected) == :gt do
      existing
    else
      selected
    end
  end

  defp logical_observed_at(snapshot) do
    PluginStateContract.snapshot_logical_observed_at(snapshot)
  end

  defp existing_state(row) do
    case Repo.query(
           """
           SELECT
             agent_id,
             gateway_id,
             partition,
             service_type,
             service_name,
             available,
             message,
             details,
             last_observed_at,
             state
           FROM platform.service_state
           WHERE agent_id = $1
             AND gateway_id = $2
             AND partition = $3
             AND service_type = $4
             AND service_name = $5
           LIMIT 1
           """,
           identity_params(row)
         ) do
      {:ok, %{rows: []}} -> {:ok, nil}
      {:ok, %{rows: [state_row]}} -> {:ok, state_from_row(state_row)}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_plugin_result_current_state, other}}
    end
  end

  defp status_from_row([
         agent_id,
         gateway_id,
         partition,
         service_type,
         service_name,
         available,
         message,
         details,
         timestamp,
         _payload_digest
       ]) do
    %{
      agent_id: agent_id,
      gateway_id: gateway_id,
      partition: partition,
      service_type: service_type,
      service_name: service_name,
      available: available,
      message: message,
      details: details,
      timestamp: timestamp
    }
  end

  defp state_from_row([
         agent_id,
         gateway_id,
         partition,
         service_type,
         service_name,
         available,
         message,
         details,
         last_observed_at,
         state
       ]) do
    %{
      agent_id: agent_id,
      gateway_id: gateway_id,
      partition: partition,
      service_type: service_type,
      service_name: service_name,
      available: available,
      message: message,
      details: details,
      timestamp: last_observed_at,
      state: state
    }
  end

  defp identity_params(row) do
    [row.agent_id, row.gateway_id, row.partition, row.service_type, row.service_name]
  end
end
