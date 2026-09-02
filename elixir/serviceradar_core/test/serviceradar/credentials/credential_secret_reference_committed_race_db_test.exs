defmodule ServiceRadar.Credentials.CredentialSecretReferenceCommittedRaceDbTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Repo

  @moduletag :integration
  @moduletag sandbox: :unboxed

  test "committed binding and deletion race cannot leave a dangling binding" do
    secret_id = Ecto.UUID.generate()
    secret_uuid = Ecto.UUID.dump!(secret_id)
    owner_id = "committed-race-#{System.unique_integer([:positive])}"
    parent = self()
    race_ref = make_ref()

    Repo.query!(
      "INSERT INTO platform.network_credential_secrets (id, name, provider, credential_kind, encrypted_secret_payload) VALUES ($1, $2, 'credential-race', 'api_token', decode('00', 'hex'))",
      [secret_uuid, "credential-race-#{owner_id}"]
    )

    on_exit(fn ->
      Repo.query!("DELETE FROM platform.network_credential_secret_bindings WHERE owner_id = $1", [
        owner_id
      ])

      Repo.query!("DELETE FROM platform.network_credential_secrets WHERE id = $1", [secret_uuid])

      assert [[0]] =
               Repo.query!(
                 "SELECT count(*) FROM platform.network_credential_secret_bindings WHERE owner_id = $1",
                 [owner_id]
               ).rows
    end)

    holder =
      Task.async(fn ->
        Repo.checkout(
          fn ->
            Repo.transaction(fn ->
              [[holder_pid]] =
                Repo.query!(
                  "SELECT pg_backend_pid() FROM platform.network_credential_secrets WHERE id = $1 FOR UPDATE",
                  [
                    secret_uuid
                  ]
                ).rows

              send(parent, {:race_locked, race_ref, holder_pid})

              receive do
                {:release_race, ^race_ref} -> :ok
              after
                15_000 -> raise "timed out waiting to release committed credential-secret race"
              end
            end)
          end,
          timeout: 15_000
        )
      end)

    try do
      assert_receive {:race_locked, ^race_ref, holder_backend_pid}, 15_000

      racers =
        for {kind, sql} <- [
              {:bind,
               "INSERT INTO platform.network_credential_secret_bindings (id, secret_id, owner_kind, owner_id, field_path, inserted_at) VALUES (uuid_generate_v7(), $1, 'plugin_assignment', $2, '$.race', now() AT TIME ZONE 'utc')"},
              {:delete, "DELETE FROM platform.network_credential_secrets WHERE id = $1"}
            ] do
          Task.async(fn ->
            Repo.checkout(fn ->
              [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()").rows
              send(parent, {:race_ready, race_ref, kind, backend_pid, self()})
              assert_receive {:run_race, ^race_ref}, 15_000

              result =
                case kind do
                  :bind -> Repo.query(sql, [secret_uuid, owner_id])
                  :delete -> Repo.query(sql, [secret_uuid])
                end

              {kind, race_outcome(kind, result)}
            end)
          end)
        end

      try do
        ready =
          for _ <- racers do
            assert_receive {:race_ready, ^race_ref, kind, backend_pid, racer_pid}, 15_000
            {kind, backend_pid, racer_pid}
          end

        assert 3 == MapSet.size(MapSet.new([holder_backend_pid | Enum.map(ready, &elem(&1, 1))]))

        Enum.each(ready, fn {_kind, _backend_pid, racer_pid} ->
          send(racer_pid, {:run_race, race_ref})
        end)

        assert :ok = await_lock_waits(Enum.map(ready, &elem(&1, 1)), 15_000)
        send(holder.pid, {:release_race, race_ref})
        assert {:ok, :ok} = Task.await(holder, 15_000)

        results = Enum.map(racers, &Task.await(&1, 15_000))

        assert Map.new(results) in [
                 %{bind: :committed, delete: :foreign_key_restrict_lost},
                 %{bind: :foreign_key_insert_lost, delete: :committed}
               ]

        assert [[0]] =
                 Repo.query!(
                   "SELECT count(*) FROM platform.network_credential_secret_bindings binding LEFT JOIN platform.network_credential_secrets secret ON secret.id = binding.secret_id WHERE binding.owner_id = $1 AND secret.id IS NULL",
                   [owner_id]
                 ).rows
      after
        Enum.each(racers, fn racer ->
          if Process.alive?(racer.pid), do: Task.shutdown(racer, :brutal_kill)
        end)
      end
    after
      if Process.alive?(holder.pid) do
        send(holder.pid, {:release_race, race_ref})

        if is_nil(Task.yield(holder, 1_000)) do
          Task.shutdown(holder, :brutal_kill)
        end
      end
    end
  end

  defp race_outcome(_kind, {:ok, _result}), do: :committed

  defp race_outcome(
         :delete,
         {:error,
          %Postgrex.Error{
            postgres: %{
              code: :foreign_key_violation,
              constraint: "network_credential_secret_bindings_secret_id_fkey"
            }
          }}
       ),
       do: :foreign_key_restrict_lost

  defp race_outcome(
         :bind,
         {:error,
          %Postgrex.Error{
            postgres: %{
              code: :foreign_key_violation,
              constraint: "network_credential_secret_bindings_secret_id_fkey"
            }
          }}
       ),
       do: :foreign_key_insert_lost

  defp race_outcome(kind, result), do: {:unexpected, {kind, result}}

  defp await_lock_waits(backend_pids, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_lock_waits(backend_pids, deadline)
  end

  defp do_await_lock_waits(backend_pids, deadline) do
    [[count]] =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE pid = ANY($1::int[]) AND wait_event_type = 'Lock'",
        [backend_pids]
      ).rows

    cond do
      count == length(backend_pids) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("race connections did not both wait on the holder lock")

      true ->
        Process.sleep(25)
        do_await_lock_waits(backend_pids, deadline)
    end
  end
end
