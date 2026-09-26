defmodule ServiceRadar.Credentials.NetworkCredentialSecretDestroyTest do
  use ExUnit.Case, async: true

  alias Ash.Policy.Info
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials
  alias ServiceRadar.Credentials.CredentialBrokerGrant

  @manager %{
    id: "credential-delete-manager",
    role: :admin,
    permissions: MapSet.new(["settings.credentials.manage"])
  }
  @system_actor SystemActor.system(:credential_delete_test)

  test "only the deletion guard may prune a terminal or expired broker grant" do
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

    assert Info.strict_check(@manager, manager_changeset, Credentials) == false
    assert Info.strict_check(@system_actor, system_changeset, Credentials) == true
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
end
