defmodule ServiceRadar.Credentials.StubProviderGateTest do
  # Not async: the gate is global application config, and switching it off would
  # break every concurrently running test that resolves a :stub provider fixture.
  use ExUnit.Case, async: false

  alias Ash.Error.Changes.InvalidAttribute
  alias ServiceRadar.Credentials.CredentialSecretProvider
  alias ServiceRadar.Credentials.SecretBroker
  alias ServiceRadar.Credentials.SecretProviderAdapters.Stub

  @gate :stub_secret_provider_enabled

  setup do
    previous = Application.fetch_env(:serviceradar_core, @gate)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:serviceradar_core, @gate, value)
        :error -> Application.delete_env(:serviceradar_core, @gate)
      end
    end)
  end

  test "a :stub provider cannot be created while the gate is off" do
    set_gate(false)

    changeset = provider_changeset(:stub)
    refute changeset.valid?
    assert [%InvalidAttribute{field: :provider_type}] = changeset.errors

    assert provider_changeset(:openbao).valid?

    set_gate(true)
    assert provider_changeset(:stub).valid?
  end

  test "a stored :stub provider does not resolve while the gate is off" do
    set_gate(false)
    test_pid = self()

    provider = %{
      id: "provider-1",
      provider_type: :stub,
      enabled: true,
      resolution_locations: [:control_plane]
    }

    secret = %{
      id: "secret-1",
      source_type: :external_reference,
      secret_provider_id: "provider-1",
      external_secret_ref: "folders/example/token",
      metadata: %{"stub_secret_value" => "gate-sentinel"}
    }

    opts = [
      provider: provider,
      grant: %{id: "grant-1"},
      resolution_location: :control_plane,
      audit_sink: &send(test_pid, {:audit, &1})
    ]

    assert {:error, :adapter_unavailable} = SecretBroker.resolve_loaded_secret(secret, opts)
    assert_received {:audit, %{outcome: :failed, error_class: :adapter_unavailable}}

    # Naming the adapter explicitly does not get around the gate.
    assert {:error, :adapter_unavailable} =
             SecretBroker.resolve_loaded_secret(secret, Keyword.put(opts, :adapter, Stub))

    set_gate(true)

    assert {:ok, %{value: "gate-sentinel"}} = SecretBroker.resolve_loaded_secret(secret, opts)
  end

  defp set_gate(enabled?), do: Application.put_env(:serviceradar_core, @gate, enabled?)

  defp provider_changeset(provider_type) do
    Ash.Changeset.for_create(CredentialSecretProvider, :create, %{
      name: "gate-check",
      provider_type: provider_type
    })
  end
end
