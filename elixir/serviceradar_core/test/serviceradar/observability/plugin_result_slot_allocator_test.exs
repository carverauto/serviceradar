defmodule ServiceRadar.Observability.PluginResultSlotAllocatorTest do
  use ServiceRadar.Observability.PluginResultIngestorTestSupport

  alias ServiceRadar.Observability.PluginResultSlot

  @identity_count 258

  @tag timeout: 180_000
  test "legacy occupancy moves a result to an earlier complete event block" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])
    {payload, status, observed_at} = plugin_result_fixture()

    preferred_base =
      status
      |> Map.put(:timestamp, observed_at)
      |> Map.put(:details, nil)
      |> PluginResultSlot.block_base(0)

    insert_history_status(
      other_identity(status, "base"),
      %{"status" => "OK"},
      preferred_base,
      "occupied"
    )

    assert :ok = PluginResultIngestor.ingest(payload, status)

    assert [reported] = reported_history_rows(status)
    shifted_at = assert_reported_event_block(reported, observed_at)
    refute shifted_at == preferred_base
  end

  test "adjacent logical observations own separate physical blocks" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])
    {payload, status, observed_at} = plugin_result_fixture()
    next_observed_at = DateTime.add(observed_at, 1, :microsecond)

    next_payload = %{
      payload
      | "observed_at" => DateTime.to_iso8601(next_observed_at),
        "summary" => "adjacent result"
    }

    assert :ok = PluginResultIngestor.ingest(payload, status)
    assert :ok = PluginResultIngestor.ingest(next_payload, status)

    assert length(reported_history_rows(status)) == 2
    first_reported = reported_history_row(status, observed_at, "edge plugin completed")
    second_reported = reported_history_row(status, next_observed_at, "adjacent result")
    first_base = assert_reported_event_block(first_reported, observed_at)
    second_base = assert_reported_event_block(second_reported, next_observed_at)

    refute first_base == second_base
  end

  @tag sandbox: :unboxed
  @tag timeout: 300_000
  test "more than 257 synchronized identities retain distinct event blocks" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [SuccessfulHandler])

    Application.put_env(
      :serviceradar_core,
      :plugin_result_state_registry,
      AcceptingStateRegistry
    )

    {payload, base_status, observed_at} = plugin_result_fixture(assignment?: false)
    on_exit(fn -> cleanup_capacity_rows(base_status) end)

    # The allocator's legacy boundary is 257. Exactly one identity beyond it proves spillover
    # without repeating 42 end-to-end ingests that add no boundary coverage.
    statuses =
      Enum.map(1..@identity_count, fn index ->
        %{
          base_status
          | agent_id: "#{base_status.agent_id}-#{index}",
            partition: "partition-#{index}",
            service_type: "plugin-#{index}"
        }
      end)

    # This is an unboxed test because the sequential form exceeds the real 300-second timeout.
    # Ten independent connections exercise the same end-to-end capacity contract while leaving
    # two slots in the unchanged 12-connection test pool for the test process and application.
    results =
      statuses
      |> Task.async_stream(
        &PluginResultIngestor.ingest(payload, &1),
        max_concurrency: 10,
        ordered: false,
        timeout: 120_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, :ok}))

    Enum.each(1..@identity_count, fn _index ->
      assert_receive {:successful_handler_ingest, ^payload}, 1_000
    end)

    observation_timestamp = DateTime.to_iso8601(observed_at)

    reported_rows =
      Repo.query!(
        """
        SELECT timestamp, available, message, details
        FROM platform.service_status
        WHERE gateway_id = $1
          AND service_name = $2
          AND details IS JSON
          AND details::jsonb #>>
            '{_serviceradar_plugin_result,observation_timestamp}' = $3
        ORDER BY timestamp
        """,
        [base_status.gateway_id, base_status.service_name, observation_timestamp]
      ).rows

    assert length(reported_rows) == @identity_count

    block_bases =
      Enum.map(reported_rows, &assert_reported_event_block(&1, observed_at))

    assert block_bases |> MapSet.new() |> MapSet.size() == @identity_count

    assert Enum.any?(block_bases, fn block_base ->
             DateTime.diff(observed_at, block_base, :microsecond) > 1_000_000
           end)
  end

  defp other_identity(status, suffix) do
    %{
      status
      | agent_id: "#{status.agent_id}-#{suffix}",
        partition: "#{status.partition}-#{suffix}",
        service_type: "#{status.service_type}-#{suffix}"
    }
  end

  defp cleanup_capacity_rows(status) do
    agent_prefix = "#{status.agent_id}-"

    for table <- ["service_state", "service_status"] do
      Repo.query!(
        """
        DELETE FROM platform.#{table}
        WHERE gateway_id = $1
          AND service_name = $2
          AND left(agent_id, char_length($3)) = $3
        """,
        [status.gateway_id, status.service_name, agent_prefix]
      )
    end
  end
end
