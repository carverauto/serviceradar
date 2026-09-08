defmodule ServiceRadar.Observability.PluginResultIngestorConflictTest do
  use ServiceRadar.Observability.PluginResultIngestorTestSupport

  @reported_marker "_serviceradar_plugin_result"

  @tag timeout: 180_000
  test "distinct same-gateway payloads at one observation persist once in either order" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])

    {healthy_payload, first_status, observed_at} = plugin_result_fixture()
    {_payload, second_status, _second_observed_at} = plugin_result_fixture()

    critical_payload = %{
      healthy_payload
      | "status" => "CRITICAL",
        "summary" => "same-observation critical result"
    }

    first_set =
      ingest_conflicting_results(
        first_status,
        [healthy_payload, critical_payload, critical_payload, healthy_payload],
        observed_at
      )

    second_set =
      ingest_conflicting_results(
        second_status,
        [critical_payload, healthy_payload, healthy_payload, critical_payload],
        observed_at
      )

    assert first_set == second_set

    assert [[false, "same-observation critical result", _timestamp]] =
             current_state_rows(first_status)

    assert [[false, "same-observation critical result", _timestamp]] =
             current_state_rows(second_status)

    reported_before_replay = MapSet.new(reported_results(first_status))
    current_before_replay = current_state_rows(first_status)

    # One replay of each digest proves idempotency here. Repeating these same two handlerless
    # payloads 130 times does not advance the separate 128-generation handler-marker window.
    Enum.each([critical_payload, healthy_payload], fn payload ->
      assert :ok = PluginResultIngestor.ingest(payload, first_status)
    end)

    assert MapSet.new(reported_results(first_status)) == reported_before_replay
    assert MapSet.size(reported_before_replay) == 2
    assert current_state_rows(first_status) == current_before_replay

    rebuild_current_states([first_status, second_status])

    assert [[false, "same-observation critical result", _timestamp]] =
             current_state_rows(first_status)

    assert [[false, "same-observation critical result", _timestamp]] =
             current_state_rows(second_status)
  end

  test "equal-availability conflicts use the payload digest in either arrival order" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])

    {first_payload, first_status, observed_at} = plugin_result_fixture()
    {_payload, second_status, _second_observed_at} = plugin_result_fixture()

    first_payload = %{first_payload | "summary" => "healthy payload alpha"}

    second_payload = %{
      first_payload
      | "status" => "WARNING",
        "summary" => "healthy payload beta"
    }

    first_set =
      ingest_conflicting_results(
        first_status,
        [first_payload, second_payload, first_payload, second_payload],
        observed_at
      )

    second_set =
      ingest_conflicting_results(
        second_status,
        [second_payload, first_payload, second_payload, first_payload],
        observed_at
      )

    assert first_set == second_set

    {_digest, _status, expected_summary} = Enum.max_by(first_set, &elem(&1, 0))

    assert [[true, ^expected_summary, _timestamp]] = current_state_rows(first_status)
    assert [[true, ^expected_summary, _timestamp]] = current_state_rows(second_status)

    rebuild_current_states([first_status, second_status])

    assert [[true, ^expected_summary, _timestamp]] = current_state_rows(first_status)
    assert [[true, ^expected_summary, _timestamp]] = current_state_rows(second_status)
  end

  test "same-payload envelope availability conflicts prefer unavailable in either order" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])

    {payload, first_status, _observed_at} = plugin_result_fixture()
    {_payload, second_status, _second_observed_at} = plugin_result_fixture()

    available_status = Map.put(first_status, :available, true)
    unavailable_status = Map.put(first_status, :available, false)

    Enum.each(
      [available_status, unavailable_status, available_status, unavailable_status],
      fn status -> assert :ok = PluginResultIngestor.ingest(payload, status) end
    )

    second_available_status = Map.put(second_status, :available, true)
    second_unavailable_status = Map.put(second_status, :available, false)

    Enum.each(
      [
        second_unavailable_status,
        second_available_status,
        second_unavailable_status,
        second_available_status
      ],
      fn status -> assert :ok = PluginResultIngestor.ingest(payload, status) end
    )

    assert [[false, "edge plugin completed", _timestamp]] = current_state_rows(first_status)
    assert [[false, "edge plugin completed", _timestamp]] = current_state_rows(second_status)

    rebuild_current_states([first_status, second_status])

    assert [[false, "edge plugin completed", _timestamp]] = current_state_rows(first_status)
    assert [[false, "edge plugin completed", _timestamp]] = current_state_rows(second_status)
  end

  test "explicit digests deterministically outrank distinct legacy payloads" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])

    {base_payload, legacy_first_status, observed_at} = plugin_result_fixture()
    {_payload, explicit_first_status, _other_observed_at} = plugin_result_fixture()

    legacy_payload = %{base_payload | "summary" => "payload-1"}
    explicit_payload = %{base_payload | "summary" => "payload-3"}
    legacy_details = legacy_reported_details(legacy_payload, observed_at)

    insert_history_status(
      legacy_first_status,
      legacy_details,
      observed_at,
      "payload-1"
    )

    assert :ok = PluginResultIngestor.ingest(explicit_payload, legacy_first_status)
    assert :ok = PluginResultIngestor.ingest(explicit_payload, explicit_first_status)

    insert_history_status(
      explicit_first_status,
      legacy_details,
      observed_at,
      "payload-1"
    )

    assert [[true, "payload-3", _timestamp]] = current_state_rows(legacy_first_status)
    assert [[true, "payload-3", _timestamp]] = current_state_rows(explicit_first_status)

    rebuild_current_states([legacy_first_status, explicit_first_status])

    assert [[true, "payload-3", _timestamp]] = current_state_rows(legacy_first_status)
    assert [[true, "payload-3", _timestamp]] = current_state_rows(explicit_first_status)
  end

  defp ingest_conflicting_results(status, payloads, observed_at) do
    Enum.each(payloads, fn payload ->
      assert :ok = PluginResultIngestor.ingest(payload, status)
    end)

    reported = reported_results(status)
    assert length(reported) == 2

    Enum.each(reported, fn result ->
      assert get_in(result, [@reported_marker, "observation_timestamp"]) ==
               DateTime.to_iso8601(observed_at)

      assert get_in(result, [@reported_marker, "payload_digest"]) =~ ~r/^[0-9a-f]{64}$/
    end)

    MapSet.new(reported, fn result ->
      marker = Map.fetch!(result, @reported_marker)

      {
        marker["payload_digest"],
        result["status"],
        result["summary"]
      }
    end)
  end

  defp reported_results(status) do
    status
    |> decoded_history_details()
    |> Enum.filter(&(get_in(&1, [@reported_marker, "kind"]) == "reported"))
  end

  defp decoded_history_details(status) do
    Enum.map(history_rows(status), fn [_timestamp, _available, _message, details] ->
      Jason.decode!(details)
    end)
  end

  defp legacy_reported_details(payload, observed_at) do
    Map.put(payload, @reported_marker, %{
      "kind" => "reported",
      "observation_timestamp" => DateTime.to_iso8601(observed_at),
      "version" => 1
    })
  end

  defp rebuild_current_states(statuses) do
    agent_ids = Enum.map(statuses, & &1.agent_id)

    Repo.query!(
      "DELETE FROM platform.service_state WHERE agent_id = ANY($1::text[])",
      [agent_ids]
    )

    assert {:ok, _count} =
             ServiceStateRegistry.repair_plugin_states_from_history(interval: "1 day", limit: 100)
  end
end
