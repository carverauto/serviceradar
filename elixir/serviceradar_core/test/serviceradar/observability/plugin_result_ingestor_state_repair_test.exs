defmodule ServiceRadar.Observability.PluginResultIngestorStateRepairTest do
  use ServiceRadar.Observability.PluginResultIngestorTestSupport

  @reported_marker "_serviceradar_plugin_result"

  test "an older real result replaces a newer assignment placeholder on the same gateway" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])

    {payload, status, _observed_at} = plugin_result_fixture()
    placeholder_at = DateTime.truncate(DateTime.utc_now(), :microsecond)

    seed_service_state(status, placeholder_at,
      available: false,
      message: "plugin assignment pending result",
      state: "active"
    )

    assert :ok = PluginResultIngestor.ingest(payload, status)

    assert [[true, "edge plugin completed", result_at]] = current_state_rows(status)
    assert DateTime.before?(result_at, placeholder_at)
  end

  test "handler failure and recovery lineage is scoped to the payload digest" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])
    ReplayHandler.put_outcomes([{:error, :payload_a_failure}, :ok, :ok])

    {payload_a, status, _observed_at} = plugin_result_fixture()

    payload_b = %{
      payload_a
      | "status" => "WARNING",
        "summary" => "distinct payload b"
    }

    assert {:error, {:plugin_result_handlers_failed, [{ReplayHandler, ":payload_a_failure"}]}} =
             PluginResultIngestor.ingest(payload_a, status)

    assert :ok = PluginResultIngestor.ingest(payload_b, status)

    reported = reported_results(status)
    payload_a_digest = digest_for_summary(reported, payload_a["summary"])
    payload_b_digest = digest_for_summary(reported, payload_b["summary"])

    refute payload_a_digest == payload_b_digest

    assert %{
             "downstream_ingest" => %{
               "payload_digest" => ^payload_a_digest,
               "status" => "failed"
             }
           } = status |> current_state_details() |> Jason.decode!()

    assert Enum.any?(downstream_results(status), fn result ->
             get_in(result, ["downstream_ingest", "status"]) == "succeeded" and
               get_in(result, ["downstream_ingest", "payload_digest"]) == payload_b_digest and
               get_in(result, ["downstream_ingest", "recovered_from_failure"]) == false
           end)

    assert :ok = PluginResultIngestor.ingest(payload_a, status)

    downstream = downstream_results(status)

    assert Enum.any?(downstream, fn result ->
             get_in(result, ["downstream_ingest", "status"]) == "failed" and
               get_in(result, ["downstream_ingest", "payload_digest"]) == payload_a_digest
           end)

    assert Enum.any?(downstream, fn result ->
             get_in(result, ["downstream_ingest", "status"]) == "succeeded" and
               get_in(result, ["downstream_ingest", "payload_digest"]) == payload_a_digest and
               get_in(result, ["downstream_ingest", "recovered_from_failure"]) == true
           end)

    refute Enum.any?(downstream, fn result ->
             get_in(result, ["downstream_ingest", "payload_digest"]) == payload_b_digest and
               get_in(result, ["downstream_ingest", "recovered_from_failure"]) == true
           end)
  end

  test "recovery reconsiders competing payloads and repair replaces a populated loser" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])
    ReplayHandler.put_outcomes([{:error, :payload_a_failure}, :ok, :ok])

    {base_payload, status, observed_at} = plugin_result_fixture()

    payload_a =
      1..64
      |> Enum.map(&%{base_payload | "summary" => "recovering payload #{&1}"})
      |> Enum.min_by(&payload_digest/1)

    payload_b =
      1..64
      |> Enum.map(fn suffix ->
        %{
          base_payload
          | "status" => "CRITICAL",
            "summary" => "competing critical payload #{suffix}"
        }
      end)
      |> Enum.max_by(&payload_digest/1)

    competing_summary = payload_b["summary"]
    assert payload_digest(payload_b) > payload_digest(payload_a)

    assert {:error, {:plugin_result_handlers_failed, [{ReplayHandler, ":payload_a_failure"}]}} =
             PluginResultIngestor.ingest(payload_a, status)

    assert :ok = PluginResultIngestor.ingest(payload_b, status)
    assert :ok = PluginResultIngestor.ingest(payload_a, status)

    assert [[false, ^competing_summary, _timestamp]] = current_state_rows(status)

    reported_payload_a_digest =
      status
      |> reported_results()
      |> digest_for_summary(payload_a["summary"])

    [_timestamp, true, _message, payload_a_success_details] =
      Enum.find(history_rows(status), fn [_timestamp, _available, _message, details] ->
        decoded = Jason.decode!(details)

        get_in(decoded, ["downstream_ingest", "status"]) == "succeeded" and
          get_in(decoded, ["downstream_ingest", "payload_digest"]) == reported_payload_a_digest
      end)

    wrong_timestamp = DateTime.add(observed_at, 255, :microsecond)

    Repo.query!(
      """
      UPDATE platform.service_state
      SET available = true,
          message = $1,
          details = $2,
          last_observed_at = $3,
          state = 'active'
      WHERE agent_id = $4
        AND gateway_id = $5
        AND partition = $6
        AND service_type = $7
        AND service_name = $8
      """,
      [
        payload_a["summary"],
        payload_a_success_details,
        wrong_timestamp,
        status.agent_id,
        status.gateway_id,
        status.partition,
        status.service_type,
        status.service_name
      ]
    )

    assert [[true, payload_a_summary, ^wrong_timestamp]] = current_state_rows(status)
    assert payload_a_summary == payload_a["summary"]

    assert {:ok, _count} =
             ServiceStateRegistry.repair_plugin_states_from_history(interval: "1 day", limit: 100)

    assert [[false, ^competing_summary, _timestamp]] = current_state_rows(status)
  end

  defp reported_results(status) do
    status
    |> decoded_history_details()
    |> Enum.filter(&(get_in(&1, [@reported_marker, "kind"]) == "reported"))
  end

  defp downstream_results(status) do
    status
    |> decoded_history_details()
    |> Enum.filter(&is_map(Map.get(&1, "downstream_ingest")))
  end

  defp decoded_history_details(status) do
    Enum.map(history_rows(status), fn [_timestamp, _available, _message, details] ->
      Jason.decode!(details)
    end)
  end

  defp digest_for_summary(results, summary) do
    results
    |> Enum.find(&(Map.get(&1, "summary") == summary))
    |> get_in([@reported_marker, "payload_digest"])
  end

  defp payload_digest(payload) do
    canonical = payload |> Jason.encode!() |> Jason.decode!()

    canonical
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
