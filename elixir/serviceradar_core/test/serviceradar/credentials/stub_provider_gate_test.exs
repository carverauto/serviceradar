defmodule ServiceRadar.Credentials.StubProviderGateTest do
  # Not async: the gate is global application config, and switching it off would
  # break every concurrently running test that resolves a :stub provider fixture.
  use ExUnit.Case, async: false

  alias Ash.Error.Changes.InvalidAttribute
  alias ServiceRadar.Credentials.CredentialSecretProvider

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

  defp set_gate(enabled?), do: Application.put_env(:serviceradar_core, @gate, enabled?)

  defp provider_changeset(provider_type) do
    Ash.Changeset.for_create(CredentialSecretProvider, :create, %{
      name: "gate-check",
      provider_type: provider_type
    })
  end
end
