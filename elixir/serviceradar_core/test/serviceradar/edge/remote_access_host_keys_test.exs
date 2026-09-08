defmodule ServiceRadar.Edge.RemoteAccessHostKeysTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.RemoteAccessHostKey
  alias ServiceRadar.Edge.RemoteAccessHostKeys

  defmodule AuditSink do
    @moduledoc false

    def write_async(opts) do
      send(
        Process.get(:remote_access_host_key_audit_owner),
        {:remote_access_host_key_audit, opts}
      )

      :ok
    end
  end

  @system_actor SystemActor.system(:remote_access_host_keys_test)

  setup do
    Process.put(:remote_access_host_key_audit_owner, self())
    :ok
  end

  test "trust-on-first-use observation creates a trusted host key without reusable secrets" do
    target_host = unique_host("tofu")

    assert {:ok,
            %{host_key: %RemoteAccessHostKey{} = host_key, decision: :trusted, conflict_with: []}} =
             RemoteAccessHostKeys.observe(
               observation(target_host,
                 source: :trust_on_first_use,
                 metadata: %{"private_key" => "must-not-persist", "safe" => "kept"}
               ),
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert host_key.target_host == target_host
    assert host_key.status == :trusted
    assert host_key.source == :trust_on_first_use
    assert host_key.trusted_by == @system_actor.id
    assert host_key.metadata["private_key"] == "REDACTED"
    assert host_key.metadata["safe"] == "kept"
    refute inspect(host_key) =~ "must-not-persist"

    assert_receive {:remote_access_host_key_audit, audit}
    assert audit[:action] == :remote_access_host_key_observed
    assert audit[:details][:status] == "trusted"
    refute inspect(audit) =~ "must-not-persist"
  end

  test "new key for a trusted target is recorded as conflict and can be rotated" do
    target_host = unique_host("rotate")

    assert {:ok, %{host_key: trusted}} =
             RemoteAccessHostKeys.observe(
               observation(target_host,
                 fingerprint_sha256: "SHA256:old",
                 source: :trust_on_first_use
               ),
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_host_key_audit, _created_audit}

    assert {:ok, %{host_key: conflict, decision: :conflict, conflict_with: [trusted_id]}} =
             RemoteAccessHostKeys.observe(
               observation(target_host,
                 fingerprint_sha256: "SHA256:new",
                 source: :agent_observed
               ),
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert trusted_id == trusted.id
    assert conflict.status == :conflict

    assert_receive {:remote_access_host_key_audit, conflict_audit}
    assert conflict_audit[:action] == :remote_access_host_key_conflict_detected
    assert conflict_audit[:details][:conflict_with] == [trusted.id]

    assert {:ok, %{rotated: rotated_old, trusted: trusted_new}} =
             RemoteAccessHostKeys.rotate(trusted, conflict,
               actor: @system_actor,
               audit_writer: AuditSink,
               reason: "scheduled rotation"
             )

    assert rotated_old.status == :rotated
    assert rotated_old.replacement_host_key_id == trusted_new.id
    assert rotated_old.rotation_reason == "scheduled rotation"
    assert trusted_new.status == :trusted
    assert trusted_new.supersedes_host_key_id == trusted.id

    assert_receive {:remote_access_host_key_audit, trust_audit}
    assert trust_audit[:action] == :remote_access_host_key_trusted
    assert trust_audit[:details][:supersedes_host_key_id] == trusted.id

    assert_receive {:remote_access_host_key_audit, rotation_audit}
    assert rotation_audit[:action] == :remote_access_host_key_rotated
    assert rotation_audit[:details][:replacement_host_key_id] == trusted_new.id
    assert rotation_audit[:details][:supersedes_host_key_id] == trusted.id
  end

  test "conflict host keys cannot be directly trusted and rejected keys are terminal" do
    target_host = unique_host("reject")

    assert {:ok, %{host_key: trusted}} =
             RemoteAccessHostKeys.observe(
               observation(target_host,
                 fingerprint_sha256: "SHA256:trusted",
                 source: :trust_on_first_use
               ),
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_host_key_audit, _created_audit}

    assert {:ok, %{host_key: conflict}} =
             RemoteAccessHostKeys.observe(
               observation(target_host,
                 fingerprint_sha256: "SHA256:replacement",
                 source: :agent_observed
               ),
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert_receive {:remote_access_host_key_audit, _conflict_audit}
    assert conflict.status == :conflict

    assert {:error, :host_key_conflict_requires_rotation} =
             RemoteAccessHostKeys.trust(conflict,
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert {:ok, rejected} =
             RemoteAccessHostKeys.reject(conflict,
               actor: @system_actor,
               audit_writer: AuditSink,
               reason: "operator rejected key swap"
             )

    assert rejected.status == :rejected
    assert rejected.rejection_reason == "operator rejected key swap"

    assert_receive {:remote_access_host_key_audit, reject_audit}
    assert reject_audit[:action] == :remote_access_host_key_rejected
    assert reject_audit[:details][:status] == "rejected"

    assert {:error, :host_key_rejected} =
             RemoteAccessHostKeys.trust(rejected,
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert {:error, :host_key_rejected} =
             RemoteAccessHostKeys.rotate(trusted, rejected,
               actor: @system_actor,
               audit_writer: AuditSink,
               reason: "should fail"
             )
  end

  test "repeat observation increments seen count for the same target fingerprint" do
    target_host = unique_host("seen")

    assert {:ok, %{host_key: first}} =
             RemoteAccessHostKeys.observe(
               observation(target_host, fingerprint_sha256: "SHA256:repeat"),
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert first.seen_count == 1

    assert {:ok, %{host_key: second, decision: :pending}} =
             RemoteAccessHostKeys.observe(
               observation(target_host, fingerprint_sha256: "SHA256:repeat"),
               actor: @system_actor,
               audit_writer: AuditSink
             )

    assert second.id == first.id
    assert second.seen_count == 2
  end

  defp observation(target_host, overrides) do
    Map.merge(
      %{
        device_uid: "device-#{target_host}",
        target_host: target_host,
        target_port: 22,
        protocol: :ssh,
        agent_id: "agent-host-key-test",
        gateway_id: "gateway-host-key-test",
        key_type: "ssh-ed25519",
        fingerprint_sha256: "SHA256:#{target_host}",
        public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI#{target_host}",
        source: :agent_observed,
        metadata: %{}
      },
      Map.new(overrides)
    )
  end

  defp unique_host(label) do
    "host-key-#{label}-#{System.unique_integer([:positive])}.example.test"
  end
end
