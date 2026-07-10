defmodule ServiceRadar.Credentials.CredentialRulesReconcileTelemetryTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.PluginAssignmentMaterializer
  alias ServiceRadar.Credentials.ProviderProfiles.UnifiProtectProfile

  @event PluginAssignmentMaterializer.reconcile_telemetry_event()

  defmodule FakeReconciler do
    @moduledoc false
    def reconcile(_policy, _input_defs, _opts) do
      {:ok, %{resolved_inputs: 2, desired_assignments: 3, upserted: 1, unchanged: 2, disabled: 1}}
    end
  end

  defmodule FailingReconciler do
    @moduledoc false
    def reconcile(_policy, _input_defs, _opts), do: {:error, [:boom]}
  end

  setup do
    :telemetry_test.attach_event_handlers(self(), [@event])
    :ok
  end

  defp camera_rule do
    %{
      id: "cam-rule",
      secret_id: "018f3f56-aaaa-7bbb-8ccc-123456789abc",
      enabled: true,
      priority: 100,
      provider: "unifi-protect",
      auth_method: :api_key,
      purpose: :camera_inventory,
      target_query: "in:devices hostname:udm-*",
      tls_policy: :verify,
      scope_type: :agent,
      scope_value: "agent-cam",
      metadata: %{}
    }
  end

  test "emits counts per provider/purpose when work is done" do
    assert {:ok, summary} =
             PluginAssignmentMaterializer.reconcile_provider_for_agent(
               UnifiProtectProfile,
               "agent-cam",
               :camera_inventory,
               rules: [camera_rule()],
               plugin_package: %{id: "pkg-cam"},
               reconciler: FakeReconciler,
               actor: %{id: "operator"}
             )

    assert summary.rules == 1
    assert summary.upserted == 1
    assert summary.skips == %{}

    assert_receive {@event, _ref, measurements, metadata}

    assert measurements == %{
             rules_matched: 1,
             targets_resolved: 2,
             desired_assignments: 3,
             assignments_written: 1,
             assignments_unchanged: 2,
             assignments_disabled: 1
           }

    assert metadata.provider == "unifi-protect"
    assert metadata.purpose == :camera_inventory
    assert metadata.agent_id == "agent-cam"
    assert metadata.status == :ok
    assert metadata.skips == %{}
  end

  test "no-op reconciles are distinguishable: zero counts plus a skip reason" do
    assert {:ok, summary} =
             PluginAssignmentMaterializer.reconcile_provider_for_agent(
               UnifiProtectProfile,
               "agent-cam",
               :camera_inventory,
               rules: [],
               reconciler: FakeReconciler,
               actor: %{id: "operator"}
             )

    assert summary.rules == 0
    assert summary.skips == %{no_matching_rules: 1}

    assert_receive {@event, _ref, measurements, metadata}

    assert measurements.rules_matched == 0
    assert measurements.assignments_written == 0
    assert metadata.status == :ok
    assert metadata.skips == %{no_matching_rules: 1}
  end

  test "errors emit an error-status event" do
    failing_reconciler = __MODULE__.FailingReconciler

    assert {:error, _reason} =
             PluginAssignmentMaterializer.reconcile_provider_for_agent(
               UnifiProtectProfile,
               "agent-cam",
               :camera_inventory,
               rules: [camera_rule()],
               plugin_package: %{id: "pkg-cam"},
               reconciler: failing_reconciler,
               actor: %{id: "operator"}
             )

    assert_receive {@event, _ref, measurements, metadata}
    assert measurements.rules_matched == 0
    assert metadata.status == :error
    assert metadata.error
  end
end
