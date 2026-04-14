defmodule ServiceRadar.Integrations.IntegrationSourceNorthboundTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = %{id: "system", email: "system@serviceradar", role: :admin}
    {:ok, actor: actor}
  end

  test "stores northbound fields on create and exports them via the resource", %{actor: actor} do
    source =
      create_source!(actor,
        name: unique_name("northbound-create"),
        northbound_enabled: true,
        northbound_interval_seconds: 900
      )

    assert Map.get(source, :northbound_enabled) == true
    assert Map.get(source, :northbound_interval_seconds) == 900
    assert Map.get(source, :northbound_status) == :idle
    assert Map.get(source, :northbound_consecutive_failures) == 0
  end

  test "northbound_success resets failures and records counts", %{actor: actor} do
    source = create_source!(actor, name: unique_name("northbound-success"))

    {:ok, running} = update_with_action(source, :northbound_start, %{device_count: 25}, actor)

    {:ok, failed} =
      update_with_action(
        running,
        :northbound_failed,
        %{result: :failed, device_count: 25, error_message: "timeout"},
        actor
      )

    assert Map.get(failed, :northbound_status) == :failed
    assert Map.get(failed, :northbound_consecutive_failures) == 1
    assert Map.get(failed, :northbound_last_error_message) == "timeout"

    {:ok, success} =
      update_with_action(
        failed,
        :northbound_success,
        %{result: :success, device_count: 25, updated_count: 20, skipped_count: 5},
        actor
      )

    assert Map.get(success, :northbound_status) == :success
    assert Map.get(success, :northbound_last_result) == :success
    assert Map.get(success, :northbound_last_device_count) == 25
    assert Map.get(success, :northbound_last_updated_count) == 20
    assert Map.get(success, :northbound_last_skipped_count) == 5
    assert Map.get(success, :northbound_last_error_message) == nil
    assert Map.get(success, :northbound_consecutive_failures) == 0
    assert Map.get(success, :northbound_last_run_at)
  end

  test "northbound_failed increments failures across runs", %{actor: actor} do
    source = create_source!(actor, name: unique_name("northbound-failure"))

    {:ok, running_once} =
      update_with_action(source, :northbound_start, %{device_count: 10}, actor)

    {:ok, failed_once} =
      update_with_action(
        running_once,
        :northbound_failed,
        %{result: :failed, device_count: 10, error_message: "boom"},
        actor
      )

    {:ok, running_twice} =
      update_with_action(failed_once, :northbound_start, %{device_count: 12}, actor)

    {:ok, failed_twice} =
      update_with_action(
        running_twice,
        :northbound_failed,
        %{result: :timeout, device_count: 12, error_message: "still boom"},
        actor
      )

    assert Map.get(failed_twice, :northbound_status) == :failed
    assert Map.get(failed_twice, :northbound_last_result) == :timeout
    assert Map.get(failed_twice, :northbound_last_device_count) == 12
    assert Map.get(failed_twice, :northbound_last_error_message) == "still boom"
    assert Map.get(failed_twice, :northbound_consecutive_failures) == 2
  end

  defp create_source!(actor, attrs) do
    endpoint = "https://example.invalid/#{System.unique_integer([:positive])}"

    defaults = %{
      name: unique_name("armis-source"),
      source_type: :armis,
      endpoint: endpoint
    }

    IntegrationSource
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, Map.new(attrs)), actor: actor)
    |> Ash.Changeset.set_argument(:credentials, %{token: "secret"})
    |> Ash.create(actor: actor)
    |> case do
      {:ok, source} -> source
      {:error, reason} -> raise "failed to create integration source: #{inspect(reason)}"
    end
  end

  defp update_with_action(record, action, params, actor) do
    record
    |> Ash.Changeset.for_update(action, params, actor: actor)
    |> Ash.update(actor: actor)
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
