defmodule ServiceRadar.Credentials.CredentialEventWriterResolutionIntegrationTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialEventWriter
  alias ServiceRadar.Monitoring.OcsfEvent
  alias ServiceRadar.TestSupport

  @moduletag :integration

  @flag :credential_resolution_audit_success_events

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    original = Application.get_env(:serviceradar_core, @flag)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:serviceradar_core, @flag)
        value -> Application.put_env(:serviceradar_core, @flag, value)
      end
    end)

    Application.delete_env(:serviceradar_core, @flag)
    :ok
  end

  test "a routine success writes NO ocsf event by default" do
    secret_id = Ecto.UUID.generate()

    assert :ok = CredentialEventWriter.write_secret_resolution(attrs(secret_id, :success))

    assert resolution_event_count(secret_id) == 0
  end

  test "a failure DOES write an ocsf event" do
    secret_id = Ecto.UUID.generate()

    assert :ok = CredentialEventWriter.write_secret_resolution(attrs(secret_id, :failed))

    assert resolution_event_count(secret_id) == 1
  end

  test "a denied outcome DOES write an ocsf event" do
    secret_id = Ecto.UUID.generate()

    assert :ok = CredentialEventWriter.write_secret_resolution(attrs(secret_id, :denied))

    assert resolution_event_count(secret_id) == 1
  end

  test "enabling the flag re-enables success emission" do
    Application.put_env(:serviceradar_core, @flag, true)
    secret_id = Ecto.UUID.generate()

    assert :ok = CredentialEventWriter.write_secret_resolution(attrs(secret_id, :success))

    assert resolution_event_count(secret_id) == 1
  end

  defp attrs(secret_id, outcome) do
    %{
      secret_id: secret_id,
      secret_provider_id: Ecto.UUID.generate(),
      consumer_kind: :device_task,
      consumer_id: "consumer-#{System.unique_integer([:positive])}",
      purpose: "credential-event-writer-test",
      resolution_location: :control_plane,
      outcome: outcome
    }
  end

  defp resolution_event_count(secret_id) do
    actor = SystemActor.system(:credential_event_writer_test)

    OcsfEvent
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.read!(actor: actor)
    |> Enum.count(fn event ->
      get_in(event.unmapped || %{}, ["event_family"]) == "credential_secret_resolution" and
        get_in(event.unmapped || %{}, ["network_credential_secret_id"]) == to_string(secret_id)
    end)
  end
end
