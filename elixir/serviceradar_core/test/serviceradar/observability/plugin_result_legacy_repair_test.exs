defmodule ServiceRadar.Observability.PluginResultLegacyRepairTest do
  use ServiceRadar.Observability.PluginResultIngestorTestSupport

  @reported_marker "_serviceradar_plugin_result"

  test "repair joins a legacy failure to a newer explicit-digest recovery" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])

    {payload, status, observed_at} = plugin_result_fixture()
    expected_summary = payload["summary"]
    observation_timestamp = DateTime.to_iso8601(observed_at)
    failure_at = DateTime.add(observed_at, 1, :microsecond)
    success_at = DateTime.add(observed_at, 2, :microsecond)

    reported_details =
      Map.put(payload, @reported_marker, %{
        "kind" => "reported",
        "observation_timestamp" => observation_timestamp,
        "service_id" => "legacy-service-id",
        "version" => 1
      })

    downstream_base = %{
      "generation" => 1,
      "handler_set" => %{"id" => "legacy-handler-set", "version" => 1},
      "observation_timestamp" => observation_timestamp
    }

    failure_details = %{
      "status" => "CRITICAL",
      "summary" => "legacy handler failure",
      "reported_result" => payload,
      "downstream_ingest" => Map.put(downstream_base, "status", "failed")
    }

    success_details = %{
      "status" => payload["status"],
      "summary" => payload["summary"],
      "reported_result" => payload,
      "downstream_ingest" =>
        downstream_base
        |> Map.put("status", "succeeded")
        |> Map.put("payload_digest", payload_digest(payload))
    }

    insert_history_row!(status, observed_at, true, expected_summary, reported_details)
    insert_history_row!(status, failure_at, false, "legacy handler failure", failure_details)
    insert_history_row!(status, success_at, true, expected_summary, success_details)

    seed_service_state(status, failure_at,
      available: false,
      message: "legacy handler failure",
      state: "active"
    )

    update_state_details!(status, failure_details)

    assert {:ok, _count} =
             ServiceStateRegistry.repair_plugin_states_from_history(
               interval: "1 day",
               batch_size: 100
             )

    assert [[true, ^expected_summary, ^success_at]] = current_state_rows(status)

    assert %{"downstream_ingest" => %{"status" => "succeeded"}} =
             status |> current_state_details() |> Jason.decode!()
  end

  defp update_state_details!(status, details) do
    Repo.query!(
      """
      UPDATE platform.service_state
      SET details = $1
      WHERE agent_id = $2
        AND gateway_id = $3
        AND partition = $4
        AND service_type = $5
        AND service_name = $6
      """,
      [
        Jason.encode!(details),
        status.agent_id,
        status.gateway_id,
        status.partition,
        status.service_type,
        status.service_name
      ]
    )
  end

  defp insert_history_row!(status, timestamp, available, message, details) do
    Repo.query!(
      """
      INSERT INTO platform.service_status (
        timestamp,
        gateway_id,
        agent_id,
        service_name,
        service_type,
        available,
        message,
        details,
        partition,
        created_at
      )
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $1)
      """,
      [
        timestamp,
        status.gateway_id,
        status.agent_id,
        status.service_name,
        status.service_type,
        available,
        message,
        Jason.encode!(details),
        status.partition
      ]
    )
  end

  defp payload_digest(payload) do
    canonical = payload |> Jason.encode!() |> Jason.decode!()

    canonical
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
