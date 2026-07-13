defmodule ServiceRadar.Automation.Ansible.MutationLifecycleTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.MutationLifecycle
  alias ServiceRadar.TestSupport.MutationLifecycleFakeActions, as: FakeActions

  @controller_id "018f3f56-1111-7222-8333-123456789abc"
  @execution_id "018f3f56-1111-7222-8333-123456789abd"
  @target_id "018f3f56-1111-7222-8333-123456789abe"
  @transaction_id "018f3f56-1111-7222-8333-123456789abf"
  @now ~U[2026-07-12 18:00:00.000000Z]
  @deadline ~U[2026-07-12 18:10:00.000000Z]

  setup do
    Process.put(:test_pid, self())
    Process.put(:mutation_lifecycle_phases, [])
    :ok
  end

  defp context(overrides \\ %{}) do
    base = %{
      execution: %{
        id: @execution_id,
        controller_id: @controller_id,
        inventory_id: 34,
        awx_job_id: 77,
        job_template_id: 42,
        scm_revision: String.duplicate("a", 40),
        state: :scope_verified
      },
      target: %{
        id: @target_id,
        execution_id: @execution_id,
        membership_id: "018f3f56-1111-7222-8333-123456789ac0",
        controller_id: @controller_id,
        inventory_id: 34,
        awx_host_id: 7,
        canonical_device_uid: "sr:device-7"
      },
      action: "remote_access.ssh_ca.trust.install",
      policy_digest: String.duplicate("b", 64),
      deadline_at: @deadline
    }

    Map.merge(base, overrides)
  end

  defp source(overrides \\ %{}) do
    Map.merge(
      %{
        authenticated: true,
        source_kind: "awx_controller_lifecycle",
        transport: "mtls_edge_command",
        execution_id: @execution_id,
        execution_target_id: @target_id,
        controller_id: @controller_id,
        inventory_id: 34,
        awx_job_id: 77,
        awx_host_id: 7,
        template_id: 42,
        scm_revision: String.duplicate("a", 40),
        action: "remote_access.ssh_ca.trust.install",
        policy_digest: String.duplicate("b", 64),
        command_id: "018f3f56-1111-7222-8333-123456789ac1"
      },
      overrides
    )
  end

  defp envelope(phase, generation, previous_phase, overrides \\ %{}) do
    base = %{
      "schema" => "automation.mutation_phase.v1",
      "execution_id" => @execution_id,
      "execution_target_id" => @target_id,
      "controller_id" => @controller_id,
      "inventory_id" => 34,
      "awx_job_id" => 77,
      "awx_host_id" => 7,
      "canonical_device_uid" => "sr:device-7",
      "transaction_id" => @transaction_id,
      "generation" => generation,
      "idempotency_key" => "event-#{generation}",
      "previous_phase" => previous_phase && Atom.to_string(previous_phase),
      "phase" => Atom.to_string(phase),
      "action" => "remote_access.ssh_ca.trust.install",
      "template_id" => 42,
      "scm_revision" => String.duplicate("a", 40),
      "policy_digest" => String.duplicate("b", 64),
      "outcome_digest" => String.duplicate(Integer.to_string(generation), 64),
      "deadline_at" => DateTime.to_iso8601(@deadline),
      "occurred_at" => DateTime.to_iso8601(@now)
    }

    base |> Map.merge(overrides) |> Jason.encode!()
  end

  test "persists the versioned graph through commit with exact bound evidence" do
    transitions = [
      {:initial, 1, nil},
      {:staged, 2, :initial},
      {:verified, 3, :staged},
      {:committed, 4, :verified}
    ]

    for {phase, generation, previous} <- transitions do
      assert {:ok, result} =
               MutationLifecycle.record(
                 context(),
                 envelope(phase, generation, previous),
                 source(),
                 actions: FakeActions,
                 now: @now
               )

      assert result.phase.phase == phase
      refute result.held?
      refute result.replayed?
    end

    assert_receive {:record_phase, %{phase: :initial}}
    assert_receive {:record_phase, %{phase: :staged}}
    assert_receive {:record_phase, %{phase: :verified}}
    assert_receive {:record_phase, %{phase: :committed}}
    refute_receive {:place_hold, _}
  end

  test "byte-identical replay is idempotent and does not append" do
    bytes = envelope(:initial, 1, nil)

    assert {:ok, %{replayed?: false}} =
             MutationLifecycle.record(context(), bytes, source(),
               actions: FakeActions,
               now: @now
             )

    assert {:ok, %{replayed?: true, phase: replay}} =
             MutationLifecycle.record(context(), bytes, source(),
               actions: FakeActions,
               now: DateTime.add(@deadline, 3_600, :second)
             )

    assert replay.phase == :initial
    assert length(Process.get(:mutation_lifecycle_phases)) == 1
    assert_receive {:record_phase, _}
    refute_receive {:record_phase, _}
    refute_receive {:place_hold, _}
  end

  test "same idempotency key with different bytes becomes unknown and device-wide held" do
    original = envelope(:initial, 1, nil)

    assert {:ok, _} =
             MutationLifecycle.record(context(), original, source(),
               actions: FakeActions,
               now: @now
             )

    conflict =
      envelope(:initial, 1, nil, %{
        "idempotency_key" => "event-1",
        "outcome_digest" => String.duplicate("c", 64)
      })

    assert {:error, {:mutation_state_unknown, {:conflicting_replay, "event-1"}, result}} =
             MutationLifecycle.record(context(), conflict, source(),
               actions: FakeActions,
               now: @now
             )

    assert result.held?
    assert result.phase.phase == :unknown
    assert_receive {:place_hold, %{canonical_device_uid: "sr:device-7", phase: :unknown}}
  end

  test "unauthenticated or differently bound controller evidence fails closed" do
    assert {:error, {:mutation_state_unknown, :unauthenticated_mutation_evidence, result}} =
             MutationLifecycle.record(
               context(),
               envelope(:initial, 1, nil),
               source(%{authenticated: false}),
               actions: FakeActions,
               now: @now
             )

    assert result.held?
    assert_receive {:place_hold, %{canonical_device_uid: "sr:device-7"}}

    Process.put(:mutation_lifecycle_phases, [])

    assert {:error, {:mutation_state_unknown, :mutation_host_mismatch, _}} =
             MutationLifecycle.record(
               context(),
               envelope(:initial, 1, nil, %{"awx_host_id" => 8}),
               source(),
               actions: FakeActions,
               now: @now
             )
  end

  test "out-of-order, terminal-following, and expired evidence becomes unknown" do
    assert {:error, {:mutation_state_unknown, :mutation_previous_phase_mismatch, first}} =
             MutationLifecycle.record(
               context(),
               envelope(:staged, 1, :initial),
               source(),
               actions: FakeActions,
               now: @now
             )

    assert first.held?

    Process.put(:mutation_lifecycle_phases, [])

    for {phase, generation, previous} <- [
          {:initial, 1, nil},
          {:staged, 2, :initial},
          {:verified, 3, :staged},
          {:committed, 4, :verified}
        ] do
      assert {:ok, _} =
               MutationLifecycle.record(
                 context(),
                 envelope(phase, generation, previous),
                 source(),
                 actions: FakeActions,
                 now: @now
               )
    end

    assert {:error, {:mutation_state_unknown, :mutation_transition_invalid, terminal}} =
             MutationLifecycle.record(
               context(),
               envelope(:rolled_back, 5, :committed),
               source(),
               actions: FakeActions,
               now: @now
             )

    assert terminal.phase.phase == :unknown

    Process.put(:mutation_lifecycle_phases, [])
    expired_now = DateTime.add(@deadline, 1, :second)

    assert {:error, {:mutation_state_unknown, :mutation_deadline_expired, expired}} =
             MutationLifecycle.record(
               context(),
               envelope(:initial, 1, nil),
               source(),
               actions: FakeActions,
               now: expired_now
             )

    assert expired.held?
  end

  test "watchdog turns an overdue staged transaction into unknown plus hold" do
    assert {:ok, _} =
             MutationLifecycle.record(
               context(),
               envelope(:initial, 1, nil),
               source(),
               actions: FakeActions,
               now: @now
             )

    assert {:ok, _} =
             MutationLifecycle.record(
               context(),
               envelope(:staged, 2, :initial),
               source(),
               actions: FakeActions,
               now: @now
             )

    assert {:ok, result} =
             MutationLifecycle.expire(context(),
               actions: FakeActions,
               now: DateTime.add(@deadline, 1, :second)
             )

    assert result.expired?
    assert result.held?
    assert result.phase.phase == :unknown
    assert_receive {:place_hold, %{canonical_device_uid: "sr:device-7", phase: :unknown}}
  end

  test "critical evidence records the phase and a canonical-device hold atomically" do
    for {phase, generation, previous} <- [
          {:initial, 1, nil},
          {:staged, 2, :initial}
        ] do
      assert {:ok, _} =
               MutationLifecycle.record(
                 context(),
                 envelope(phase, generation, previous),
                 source(),
                 actions: FakeActions,
                 now: @now
               )
    end

    assert {:ok, %{held?: true, phase: critical}} =
             MutationLifecycle.record(
               context(),
               envelope(:critical, 3, :staged),
               source(),
               actions: FakeActions,
               now: @now
             )

    assert critical.phase == :critical
    assert_receive {:place_hold, %{canonical_device_uid: "sr:device-7", phase: :critical}}
  end
end
