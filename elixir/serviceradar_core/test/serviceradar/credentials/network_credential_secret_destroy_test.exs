defmodule ServiceRadar.Credentials.NetworkCredentialSecretDestroyTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials
  alias ServiceRadar.Credentials.Changes.GuardCredentialDestroy
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.NetworkCredentialSecret

  @manager %{
    id: "credential-delete-manager",
    role: :admin,
    permissions: MapSet.new(["settings.credentials.manage"])
  }
  @system_actor SystemActor.system(:credential_delete_test)

  @restrictive_reference_constraints [
    "ansible_controllers_callback_credential_secret_id_fkey",
    "ansible_controllers_credential_secret_id_fkey",
    "ansible_controllers_execution_credential_secret_id_fkey",
    "ansible_controllers_sync_credential_secret_id_fkey",
    "ansible_playbook_repositories_credential_secret_id_fkey",
    "credential_broker_grants_secret_id_fkey",
    "device_snmp_credentials_credential_secret_id_fkey",
    "integration_sources_credential_secret_id_fkey",
    "mapper_mikrotik_controllers_credential_secret_id_fkey",
    "mapper_unifi_controllers_credential_secret_id_fkey",
    "network_credential_rules_secret_id_fkey",
    "network_credential_secret_bindings_secret_id_fkey",
    "outbound_mail_settings_api_key_secret_id_fkey",
    "outbound_mail_settings_password_secret_id_fkey",
    "plugin_repositories_credential_secret_id_fkey",
    "snmp_profiles_credential_secret_id_fkey",
    "snmp_targets_credential_secret_id_fkey"
  ]

  test "permanent deletion is an explicit transaction-backed action with UUID confirmation" do
    action = Info.action(NetworkCredentialSecret, :destroy_permanently)

    assert action.type == :destroy
    assert action.transaction? == true

    assert [%{name: :confirm_secret_id, type: Ash.Type.UUID, allow_nil?: false}] =
             action.arguments

    assert Enum.any?(action.changes, fn
             %{change: {GuardCredentialDestroy, _opts}} -> true
             _change -> false
           end)

    interface =
      Enum.find(Info.interfaces(NetworkCredentialSecret), &(&1.name == :destroy_permanently))

    assert interface.action == :destroy_permanently
    assert interface.args == [:confirm_secret_id]
  end

  test "the destructive action requires the public credential-management permission" do
    secret =
      struct(NetworkCredentialSecret,
        id: "01900000-0000-7000-8000-000000000001",
        name: "Credential",
        provider: "example-network",
        credential_kind: :api_token,
        source_type: :internal_encrypted
      )

    manager_changeset =
      Ash.Changeset.for_destroy(
        secret,
        :destroy_permanently,
        %{confirm_secret_id: secret.id},
        actor: @manager
      )

    assert Ash.Policy.Info.strict_check(@manager, manager_changeset, Credentials) == true
  end

  test "only the deletion guard may prune a terminal or expired broker grant" do
    action = Info.action(CredentialBrokerGrant, :prune_for_secret_deletion)

    assert action.type == :destroy
    assert action.transaction? == true
    assert action.public? == false
    assert [%{name: :cutoff, type: Ash.Type.UtcDatetime, allow_nil?: false}] = action.arguments

    grant =
      struct(CredentialBrokerGrant,
        id: "01900000-0000-7000-8000-000000000002",
        secret_ref: "network-secret:01900000-0000-7000-8000-000000000001",
        grant_type: "test",
        consumer_kind: :test,
        purpose: "delete-test",
        expires_at: ~U[2026-08-31 00:00:00Z],
        status: :consumed
      )

    cutoff = ~U[2026-08-31 00:00:01Z]

    manager_changeset =
      Ash.Changeset.for_destroy(grant, :prune_for_secret_deletion, %{cutoff: cutoff},
        actor: @manager
      )

    system_changeset =
      Ash.Changeset.for_destroy(grant, :prune_for_secret_deletion, %{cutoff: cutoff},
        actor: @system_actor
      )

    assert Ash.Policy.Info.strict_check(@manager, manager_changeset, Credentials) == false
    assert Ash.Policy.Info.strict_check(@system_actor, system_changeset, Credentials) == true
  end

  test "grant pruning accepts only terminal or expired live grants" do
    cutoff = ~U[2026-08-31 00:00:01Z]

    for {status, expires_at, expected_valid?} <- [
          {:consumed, ~U[2026-09-01 00:00:00Z], true},
          {:revoked, ~U[2026-09-01 00:00:00Z], true},
          {:issued, ~U[2026-08-31 00:00:00Z], true},
          {:active, ~U[2026-08-31 00:00:01Z], true},
          {:issued, ~U[2026-08-31 00:00:02Z], false},
          {:active, ~U[2026-09-01 00:00:00Z], false}
        ] do
      grant =
        struct(CredentialBrokerGrant,
          id: Ecto.UUID.generate(),
          secret_ref: "network-secret:01900000-0000-7000-8000-000000000001",
          grant_type: "test",
          consumer_kind: :test,
          purpose: "delete-test",
          expires_at: expires_at,
          status: status
        )

      changeset =
        Ash.Changeset.for_destroy(grant, :prune_for_secret_deletion, %{cutoff: cutoff},
          actor: @system_actor
        )

      assert changeset.valid? == expected_valid?,
             "expected #{status} expiring at #{expires_at} validity to be #{expected_valid?}"
    end
  end

  test "every incoming restrictive foreign key maps to one stable in-use error" do
    configured =
      NetworkCredentialSecret
      |> AshPostgres.DataLayer.Info.foreign_key_names()
      |> Map.new(fn {:id, constraint, message} -> {constraint, message} end)

    assert configured |> Map.keys() |> Enum.sort() == @restrictive_reference_constraints
    assert configured |> Map.values() |> Enum.uniq() == ["credential_in_use"]
  end
end
