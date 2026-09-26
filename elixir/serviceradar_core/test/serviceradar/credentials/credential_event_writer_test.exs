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

    test "only routine successes are suppressed from ocsf_events" do
      for outcome <- [:success, :cache_hit] do
        refute CredentialEventWriter.emit_resolution_event?(outcome), inspect(outcome)
      end

      for outcome <- [:failed, :denied, :error, :unavailable] do
        assert CredentialEventWriter.emit_resolution_event?(outcome), inspect(outcome)
      end
    end

    test "only the literal true enables routine success events" do
      Application.put_env(:serviceradar_core, @flag, "yes")

      refute CredentialEventWriter.emit_resolution_event?(:success)
    end
  end

  describe "secret_resolution_event_attrs/1" do
    test "resolution events carry only allowlisted audit fields, never caller metadata" do
      attrs =
        CredentialEventWriter.secret_resolution_event_attrs(%{
          secret_id: "secret-1",
          secret_provider_id: "provider-1",
          grant_id: "grant-1",
          consumer_kind: :northbound_action,
          consumer_id: "task-1",
          purpose: "device-task-api-call",
          target_kind: "device",
          target_id: "dev-1",
          resolution_location: :agent,
          outcome: :success,
          cache_status: :disabled,
          metadata: %{
            "external_secret_ref" => "path/to/secret",
            "token" => "secret-token",
            "note" => "caller-marker"
          }
        })

      rendered = inspect(attrs)

      assert attrs.severity == "Informational"
      assert attrs.log_name == "credential.secret_resolution"
      assert rendered =~ "secret-1"
      refute rendered =~ "secret-token"
      refute rendered =~ "path/to/secret"
      refute rendered =~ "caller-marker"
    end
  end

  describe "emit_grant_lifecycle_event?/1" do
    test "only routine grant issuance and use are suppressed from ocsf_events" do
      for action <- [:issue, :activate, :consume] do
        refute CredentialEventWriter.emit_grant_lifecycle_event?(action), inspect(action)
      end

      for action <- [:deny, :revoke, :expire] do
        assert CredentialEventWriter.emit_grant_lifecycle_event?(action), inspect(action)
      end
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
