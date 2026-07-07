defmodule ServiceRadar.Credentials.CredentialEventWriterTest do
  # Mutates application env (the success-emission flag), so it cannot be async.
  use ExUnit.Case, async: false

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
end
