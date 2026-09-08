defmodule ServiceRadar.Credentials.CredentialEventWriterTest do
  # Mutates application env (the success-emission flag), so it cannot be async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Credentials.CredentialEventWriter

  @flag :credential_resolution_audit_success_events

  setup do
    original = Application.get_env(:serviceradar_core, @flag)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:serviceradar_core, @flag)
        value -> Application.put_env(:serviceradar_core, @flag, value)
      end
    end)

    :ok
  end

  describe "emit_resolution_event?/1 (default: success suppressed)" do
    setup do
      Application.delete_env(:serviceradar_core, @flag)
      :ok
    end

    test "routine successes are NOT emitted to ocsf_events" do
      refute CredentialEventWriter.emit_resolution_event?(:success)
      refute CredentialEventWriter.emit_resolution_event?(:cache_hit)
    end

    test "security-relevant outcomes ARE emitted" do
      assert CredentialEventWriter.emit_resolution_event?(:failed)
      assert CredentialEventWriter.emit_resolution_event?(:denied)
      assert CredentialEventWriter.emit_resolution_event?(:error)
      assert CredentialEventWriter.emit_resolution_event?(:unavailable)
    end
  end

  describe "emit_resolution_event?/1 with success events enabled" do
    setup do
      Application.put_env(:serviceradar_core, @flag, true)
      :ok
    end

    test "routine successes are emitted when the flag is on" do
      assert CredentialEventWriter.emit_resolution_event?(:success)
      assert CredentialEventWriter.emit_resolution_event?(:cache_hit)
    end

    test "non-truthy flag values leave successes suppressed" do
      Application.put_env(:serviceradar_core, @flag, "yes")
      refute CredentialEventWriter.emit_resolution_event?(:success)
    end
  end

  describe "write_secret_resolution/1 short-circuit" do
    test "returns :ok for a suppressed success without touching the DB" do
      Application.delete_env(:serviceradar_core, @flag)

      # No database is required: a suppressed success returns before record_event/1.
      assert :ok =
               CredentialEventWriter.write_secret_resolution(%{
                 secret_id: Ecto.UUID.generate(),
                 outcome: :success
               })
    end
  end

  describe "emit_grant_lifecycle_event?/1" do
    test "routine grant issuance and use are NOT emitted to ocsf_events" do
      refute CredentialEventWriter.emit_grant_lifecycle_event?(:issue)
      refute CredentialEventWriter.emit_grant_lifecycle_event?(:activate)
      refute CredentialEventWriter.emit_grant_lifecycle_event?(:consume)
    end

    test "security-relevant grant outcomes ARE emitted" do
      assert CredentialEventWriter.emit_grant_lifecycle_event?(:deny)
      assert CredentialEventWriter.emit_grant_lifecycle_event?(:revoke)
      assert CredentialEventWriter.emit_grant_lifecycle_event?(:expire)
    end

    test "unknown actions fail closed to an event, never suppressed" do
      assert CredentialEventWriter.emit_grant_lifecycle_event?(:bogus_action)
      assert CredentialEventWriter.emit_grant_lifecycle_event?(nil)
    end
  end

  describe "write_broker_grant_lifecycle/2" do
    setup do
      previous_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      :ok
    end

    test "routine issue is a debug log, not an ocsf event" do
      grant = grant_fixture(:issued)
      grant_id = grant.id

      log =
        capture_log([level: :debug], fn ->
          assert :ok = CredentialEventWriter.write_broker_grant_lifecycle(grant, :issue)
        end)

      assert log =~ "Credential broker grant #{grant_id} issue"
      refute log =~ "Failed to write credential OCSF event"
    end
  end

  defp grant_fixture(status) do
    %{
      id: Ecto.UUID.generate(),
      secret_id: Ecto.UUID.generate(),
      grant_type: "unit_test",
      consumer_kind: :device_task,
      consumer_id: "consumer-1",
      purpose: "unit-test",
      target_kind: "device",
      target_id: "device-1",
      agent_id: "agent-1",
      resolution_location: :agent,
      status: status
    }
  end
end
