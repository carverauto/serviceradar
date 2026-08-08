defmodule ServiceRadar.Automation.Ansible.AutomationAwxLaunchPreflightEvidenceTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AutomationAwxLaunchPreflightEvidence

  @moduletag :requires_app

  @system_actor SystemActor.system(:awx_launch_preflight_evidence_test)
  @run_viewer %{
    id: "user:run-viewer",
    role: :viewer,
    permissions: MapSet.new(["ansible.runs.view"])
  }

  test "records bounded secret-free preflight evidence through a system-only append action" do
    changeset = changeset(valid_attrs())

    assert changeset.valid?
    assert Ash.can?({AutomationAwxLaunchPreflightEvidence, :record}, @system_actor)
    refute Ash.can?({AutomationAwxLaunchPreflightEvidence, :record}, @run_viewer)

    for action <- [:read, :by_id, :by_command_id, :for_binding] do
      assert Ash.can?({AutomationAwxLaunchPreflightEvidence, action}, @run_viewer)
    end
  end

  test "is append-only and cannot persist mutable execution links or payloads" do
    action_types = AutomationAwxLaunchPreflightEvidence |> Info.actions() |> Enum.map(& &1.type)

    assert :create in action_types
    refute :update in action_types
    refute :destroy in action_types

    forbidden =
      ~w(operation_id execution_id operation execution payload metadata raw_response credential bearer token secret)a

    refute Enum.any?(
             Info.attributes(AutomationAwxLaunchPreflightEvidence),
             &(&1.name in forbidden)
           )

    record = Info.action(AutomationAwxLaunchPreflightEvidence, :record)
    refute :operation_id in record.accept
    refute :execution_id in record.accept
    refute :payload in record.accept
  end

  test "requires canonical digests and an expiry after verification" do
    refute_valid(%{live_launch_snapshot_digest: "not-a-digest"}, "lowercase SHA-256")

    refute_valid(
      %{expires_at: ~U[2026-07-14 20:00:00.000000Z]},
      "later than the verified timestamp"
    )

    refute_valid(%{dispatch_partition_id: " "}, "non-secret dispatch agent and partition")
  end

  test "uses the durable command as its idempotency identity" do
    identity =
      AutomationAwxLaunchPreflightEvidence
      |> Info.identities()
      |> Enum.find(&(&1.name == :unique_command))

    assert identity.keys == [:command_id]
  end

  defp refute_valid(overrides, message) do
    changeset = changeset(Map.merge(valid_attrs(), overrides))

    refute changeset.valid?

    assert Enum.any?(changeset.errors, fn error ->
             Exception.message(error) =~ message
           end)
  end

  defp changeset(attrs) do
    Ash.Changeset.for_create(
      AutomationAwxLaunchPreflightEvidence,
      :record,
      attrs,
      actor: @system_actor
    )
  end

  defp valid_attrs do
    digest = String.duplicate("a", 64)

    %{
      command_id: Ash.UUID.generate(),
      controller_id: Ash.UUID.generate(),
      dispatch_agent_id: "agent-farm01-01",
      dispatch_partition_id: "farm01",
      binding_id: Ash.UUID.generate(),
      binding_version: 7,
      approval_id: Ash.UUID.generate(),
      reviewed_launch_snapshot_digest: digest,
      preflight_request_digest: String.duplicate("b", 64),
      target_snapshot_digest: String.duplicate("c", 64),
      controller_security_snapshot_digest: String.duplicate("d", 64),
      live_launch_snapshot_digest: String.duplicate("e", 64),
      command_result_digest: String.duplicate("f", 64),
      verified_at: ~U[2026-07-14 20:00:00.000000Z],
      expires_at: ~U[2026-07-14 20:05:00.000000Z]
    }
  end
end
