defmodule ServiceRadar.Credentials.NetworkCredentialSecretDestroyDbTest do
  use ServiceRadar.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.CredentialUsage
  alias ServiceRadar.Credentials.CredentialUsage.Result
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Repo
  alias ServiceRadar.SNMPProfiles.SNMPProfile

  @moduletag :integration

  @manager %{
    id: "credential-delete-db-manager",
    role: :admin,
    permissions: MapSet.new(["settings.credentials.manage"])
  }
  @viewer %{id: "credential-delete-db-viewer", role: :viewer, permissions: MapSet.new()}
  @system_actor SystemActor.system(:credential_delete_db_test)

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  test "unused deletion prunes historical grants and purges every ciphertext-bearing row" do
    marker = "credential-delete-marker-#{System.unique_integer([:positive])}"
    secret = secret_fixture(marker)
    now = DateTime.truncate(DateTime.utc_now(), :second)

    terminal = grant_fixture(secret, :consumed, DateTime.add(now, 3_600, :second))
    expired = grant_fixture(secret, :issued, DateTime.add(now, -1, :second))

    assert secret_ciphertext_present?(secret.id)
    assert secret_version_count(secret.id) > 0
    assert grant_version_count(terminal.id) > 0
    assert grant_version_count(expired.id) > 0

    assert :ok = destroy_secret(secret, secret.id, @manager)

    assert row_count("network_credential_secrets", "id", secret.id) == 0
    assert secret_version_count(secret.id) == 0
    assert row_count("credential_broker_grants", "secret_id", secret.id) == 0
    assert grant_version_count(terminal.id) == 0
    assert grant_version_count(expired.id) == 0

    assert [[name, provider, kind, source, actor_id, serialized]] =
             SQL.query!(
               Repo,
               "SELECT name, provider, credential_kind, source_type, deleted_by_actor_id, to_jsonb(audit)::text FROM platform.network_credential_secret_deletion_audits audit WHERE secret_id = $1",
               [dump(secret.id)]
             ).rows

    assert name == secret.name
    assert provider == secret.provider
    assert kind == Atom.to_string(secret.credential_kind)
    assert source == Atom.to_string(secret.source_type)
    assert actor_id == @manager.id
    refute serialized =~ marker
    refute serialized =~ "encrypted_secret_payload"
    refute serialized =~ "external_secret_ref"
    refute serialized =~ "metadata"
  end

  test "confirmation, authorization, direct consumers, live grants, and unavailable usage block deletion" do
    confirmation_secret = secret_fixture("confirmation")

    assert {:error, confirmation_error} =
             destroy_secret(confirmation_secret, Ecto.UUID.generate(), @manager)

    assert Exception.message(confirmation_error) =~ "credential_confirmation_mismatch"
    assert secret_exists?(confirmation_secret.id)
    assert audit_count(confirmation_secret.id) == 0

    assert {:error, authorization_error} =
             destroy_secret(confirmation_secret, confirmation_secret.id, @viewer)

    assert match?(%Ash.Error.Forbidden{}, authorization_error)
    assert secret_exists?(confirmation_secret.id)

    used_secret = secret_fixture("direct-consumer")

    profile =
      SNMPProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Credential delete profile #{System.unique_integer([:positive])}",
          credential_secret_id: used_secret.id
        },
        actor: @manager
      )
      |> Ash.create!()

    assert {:ok, %Result{consumers: consumers}} =
             CredentialUsage.for_secret(used_secret.id, actor: @manager)

    assert Enum.any?(consumers, &(&1.kind == :snmp_profile and &1.id == profile.id))

    assert {:error, used_error} = destroy_secret(used_secret, used_secret.id, @manager)
    assert Exception.message(used_error) =~ "credential_in_use"
    assert secret_exists?(used_secret.id)
    assert audit_count(used_secret.id) == 0

    granted_secret = secret_fixture("live-grant")
    now = DateTime.truncate(DateTime.utc_now(), :second)
    live_grant = grant_fixture(granted_secret, :issued, DateTime.add(now, 3_600, :second))

    assert {:error, grant_error} = destroy_secret(granted_secret, granted_secret.id, @manager)
    assert Exception.message(grant_error) =~ "credential_in_use"
    assert secret_exists?(granted_secret.id)
    assert row_count("credential_broker_grants", "id", live_grant.id) == 1
    assert audit_count(granted_secret.id) == 0

    unavailable_secret = secret_fixture("unavailable-usage")

    SQL.query!(
      Repo,
      "INSERT INTO platform.network_credential_secret_bindings (id, secret_id, owner_kind, owner_id, field_path) VALUES (uuid_generate_v7(), $1, 'plugin_assignment', $2, '$.params.k:746f6b656e')",
      [dump(unavailable_secret.id), Ecto.UUID.generate()]
    )

    assert {:error, unavailable_error} =
             destroy_secret(unavailable_secret, unavailable_secret.id, @manager)

    assert Exception.message(unavailable_error) =~ "credential_usage_unavailable"
    assert secret_exists?(unavailable_secret.id)
    assert audit_count(unavailable_secret.id) == 0
  end

  test "audit insertion failure rolls back grant pruning and the parent deletion" do
    secret = secret_fixture("audit-rollback")
    now = DateTime.truncate(DateTime.utc_now(), :second)
    grant = grant_fixture(secret, :consumed, DateTime.add(now, 3_600, :second))
    secret_versions_before = secret_version_count(secret.id)
    grant_versions_before = grant_version_count(grant.id)
    constraint = "credential_delete_audit_failure_#{System.unique_integer([:positive])}"

    SQL.query!(
      Repo,
      "ALTER TABLE platform.network_credential_secret_deletion_audits ADD CONSTRAINT #{constraint} CHECK (secret_id <> '#{secret.id}'::uuid) NOT VALID"
    )

    try do
      assert {:error, error} = destroy_secret(secret, secret.id, @manager)
      assert Exception.message(error) =~ "credential_deletion_audit_failed"
      assert secret_exists?(secret.id)
      assert row_count("credential_broker_grants", "id", grant.id) == 1
      assert secret_version_count(secret.id) == secret_versions_before
      assert grant_version_count(grant.id) == grant_versions_before
      assert audit_count(secret.id) == 0
    after
      SQL.query!(
        Repo,
        "ALTER TABLE platform.network_credential_secret_deletion_audits DROP CONSTRAINT IF EXISTS #{constraint}"
      )
    end
  end

  defp secret_fixture(marker) do
    NetworkCredentialSecret.create_secret!(
      %{
        name: "Credential delete #{System.unique_integer([:positive])}",
        provider: "credential-delete-test",
        credential_kind: :api_token,
        secret_payload: marker,
        metadata: %{"public_test_label" => marker}
      },
      actor: @system_actor
    )
  end

  defp grant_fixture(secret, status, expires_at) do
    attrs =
      CredentialBrokerGrant.issue_attrs(%{
        secret_id: secret.id,
        grant_type: "credential-delete-test",
        consumer_kind: :test,
        consumer_id: "delete-#{System.unique_integer([:positive])}",
        purpose: "credential.delete.test",
        ttl_seconds: 300,
        expires_at: expires_at
      })

    {:ok, grant} = CredentialBrokerGrant.issue_grant(attrs, actor: @system_actor)

    case status do
      :issued ->
        grant

      terminal_status ->
        action = terminal_action(terminal_status)

        grant
        |> Ash.Changeset.for_update(action, %{}, actor: @system_actor)
        |> Ash.update!()
    end
  end

  defp terminal_action(:consumed), do: :consume
  defp terminal_action(:denied), do: :deny
  defp terminal_action(:expired), do: :expire
  defp terminal_action(:revoked), do: :revoke

  defp destroy_secret(secret, confirmation, actor) do
    secret
    |> Ash.Changeset.for_destroy(
      :destroy_permanently,
      %{confirm_secret_id: confirmation},
      actor: actor
    )
    |> Ash.destroy(actor: actor)
  end

  defp secret_exists?(secret_id),
    do: row_count("network_credential_secrets", "id", secret_id) == 1

  defp secret_ciphertext_present?(secret_id) do
    [[present?]] =
      SQL.query!(
        Repo,
        "SELECT octet_length(encrypted_secret_payload) > 0 FROM platform.network_credential_secrets WHERE id = $1",
        [dump(secret_id)]
      ).rows

    present?
  end

  defp audit_count(secret_id),
    do: row_count("network_credential_secret_deletion_audits", "secret_id", secret_id)

  defp secret_version_count(secret_id),
    do: row_count("network_credential_secret_versions", "version_source_id", secret_id)

  defp grant_version_count(grant_id),
    do: row_count("credential_broker_grant_versions", "version_source_id", grant_id)

  defp row_count(table, column, id) do
    [[count]] =
      SQL.query!(Repo, "SELECT count(*) FROM platform.#{table} WHERE #{column} = $1", [dump(id)]).rows

    count
  end

  defp dump(id), do: Ecto.UUID.dump!(id)
end

defmodule ServiceRadar.Credentials.NetworkCredentialSecretDestroyCommittedRaceDbTest do
  use ServiceRadar.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Repo

  @moduletag :integration
  @moduletag sandbox: :unboxed

  @manager %{
    id: "credential-delete-race-manager",
    role: :admin,
    permissions: MapSet.new(["settings.credentials.manage"])
  }

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  test "a committed consumer attach and guarded deletion race cannot leave a dangling reference" do
    secret =
      NetworkCredentialSecret.create_secret!(
        %{
          name: "Credential delete race #{System.unique_integer([:positive])}",
          provider: "credential-delete-race",
          credential_kind: :api_token,
          secret_payload: "credential-delete-race-marker"
        },
        actor: ServiceRadar.Actors.SystemActor.system(:credential_delete_race_test)
      )

    secret_uuid = Ecto.UUID.dump!(secret.id)
    profile_id = Ash.UUIDv7.generate()
    profile_uuid = Ecto.UUID.dump!(profile_id)
    parent = self()
    race_ref = make_ref()

    on_exit(fn ->
      SQL.query!(Repo, "DELETE FROM platform.snmp_profiles WHERE id = $1", [profile_uuid])

      SQL.query!(
        Repo,
        "DELETE FROM platform.network_credential_secret_deletion_audits WHERE secret_id = $1",
        [
          secret_uuid
        ]
      )

      SQL.query!(Repo, "DELETE FROM platform.network_credential_secrets WHERE id = $1", [
        secret_uuid
      ])
    end)

    holder = lock_secret_row(secret_uuid, parent, race_ref)

    try do
      assert_receive {:race_locked, ^race_ref, holder_backend_pid}, 15_000

      attach =
        race_task(:attach, parent, race_ref, fn ->
          SQL.query(
            Repo,
            "INSERT INTO platform.snmp_profiles (id, name, credential_secret_id) VALUES ($1, $2, $3)",
            [profile_uuid, "Credential delete race profile #{profile_id}", secret_uuid]
          )
        end)

      delete =
        race_task(:delete, parent, race_ref, fn ->
          secret
          |> Ash.Changeset.for_destroy(
            :destroy_permanently,
            %{confirm_secret_id: secret.id},
            actor: @manager
          )
          |> Ash.destroy(actor: @manager)
        end)

      racers = [attach, delete]

      try do
        ready = receive_racers(race_ref, racers)
        backend_pids = [holder_backend_pid | Enum.map(ready, &elem(&1, 1))]
        assert MapSet.size(MapSet.new(backend_pids)) == 3

        Enum.each(ready, fn {_kind, _backend_pid, racer_pid} ->
          send(racer_pid, {:run_race, race_ref})
        end)

        racer_backend_pids = Enum.map(ready, &elem(&1, 1))

        assert :ok =
                 await_racers_blocked_by_holder(
                   racer_backend_pids,
                   holder_backend_pid,
                   15_000
                 )

        send(holder.pid, {:release_race, race_ref})
        assert {:ok, :ok} = Task.await(holder, 30_000)

        results = Map.new(racers, &Task.await(&1, 30_000))

        assert results in [
                 %{attach: :committed, delete: :credential_in_use},
                 %{attach: :foreign_key_lost, delete: :committed}
               ]

        [[secret_count, profile_count]] =
          SQL.query!(
            Repo,
            "SELECT (SELECT count(*) FROM platform.network_credential_secrets WHERE id = $1), (SELECT count(*) FROM platform.snmp_profiles WHERE id = $2)",
            [secret_uuid, profile_uuid]
          ).rows

        assert {secret_count, profile_count} in [{1, 1}, {0, 0}]
      after
        Enum.each(racers, &shutdown_task/1)
      end
    after
      release_holder(holder, race_ref)
    end
  end

  defp lock_secret_row(secret_uuid, parent, race_ref) do
    Task.async(fn ->
      Repo.checkout(
        fn ->
          Repo.transaction(fn ->
            [[backend_pid]] =
              SQL.query!(
                Repo,
                "SELECT pg_backend_pid() FROM platform.network_credential_secrets WHERE id = $1 FOR UPDATE",
                [secret_uuid]
              ).rows

            send(parent, {:race_locked, race_ref, backend_pid})

            receive do
              {:release_race, ^race_ref} -> :ok
            after
              30_000 -> raise "timed out waiting to release credential deletion race"
            end
          end)
        end,
        timeout: 30_000
      )
    end)
  end

  defp race_task(kind, parent, race_ref, operation) do
    Task.async(fn ->
      Repo.checkout(
        fn ->
          [[backend_pid]] = SQL.query!(Repo, "SELECT pg_backend_pid()").rows
          send(parent, {:race_ready, race_ref, kind, backend_pid, self()})

          receive do
            {:run_race, ^race_ref} -> :ok
          after
            30_000 -> raise "timed out waiting to run #{kind} credential deletion racer"
          end

          {kind, race_outcome(kind, operation.())}
        end,
        timeout: 30_000
      )
    end)
  end

  defp receive_racers(race_ref, racers) do
    for _racer <- racers do
      assert_receive {:race_ready, ^race_ref, kind, backend_pid, racer_pid}, 15_000
      {kind, backend_pid, racer_pid}
    end
  end

  defp await_racers_blocked_by_holder(racer_backend_pids, holder_backend_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_racers_blocked(racer_backend_pids, holder_backend_pid, deadline)
  end

  defp do_await_racers_blocked(racer_backend_pids, holder_backend_pid, deadline) do
    rows =
      SQL.query!(
        Repo,
        "SELECT pid, wait_event_type, wait_event, pg_blocking_pids(pid) FROM pg_stat_activity WHERE pid = ANY($1::int[]) ORDER BY pid",
        [racer_backend_pids]
      ).rows

    lock_waiting_pids =
      for [pid, "Lock", _wait_event, _blockers] <- rows,
          do: pid

    blocker_pids =
      rows
      |> Enum.flat_map(fn [_pid, _wait_type, _wait_event, blockers] -> blockers end)
      |> MapSet.new()

    cond do
      MapSet.new(lock_waiting_pids) == MapSet.new(racer_backend_pids) and
          MapSet.member?(blocker_pids, holder_backend_pid) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "credential deletion racers never overlapped on holder backend #{holder_backend_pid}; " <>
            "expected=#{inspect(Enum.sort(racer_backend_pids))} observed=#{inspect(rows)}"
        )

      true ->
        do_await_racers_blocked(racer_backend_pids, holder_backend_pid, deadline)
    end
  end

  defp race_outcome(:attach, {:ok, %{num_rows: 1}}), do: :committed
  defp race_outcome(:delete, :ok), do: :committed

  defp race_outcome(
         :attach,
         {:error,
          %Postgrex.Error{
            postgres: %{
              code: :foreign_key_violation,
              constraint: "snmp_profiles_credential_secret_id_fkey"
            }
          }}
       ),
       do: :foreign_key_lost

  defp race_outcome(:delete, {:error, error}) do
    if Exception.message(error) =~ "credential_in_use" do
      :credential_in_use
    else
      {:unexpected, error}
    end
  end

  defp race_outcome(kind, result), do: {:unexpected, {kind, result}}

  defp release_holder(holder, race_ref) do
    if Process.alive?(holder.pid) do
      send(holder.pid, {:release_race, race_ref})
      shutdown_task(holder)
    end
  end

  defp shutdown_task(task) do
    if Process.alive?(task.pid) and is_nil(Task.yield(task, 100)) do
      Task.shutdown(task, :brutal_kill)
    end
  end
end
