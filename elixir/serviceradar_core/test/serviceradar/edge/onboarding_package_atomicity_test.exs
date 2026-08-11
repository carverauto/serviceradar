defmodule ServiceRadar.Edge.OnboardingPackageAtomicityTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.OnboardingPackages
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration
  @moduletag sandbox: :unboxed

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    previous_crypto_secret = Application.get_env(:serviceradar_core, :crypto_secret)
    Application.put_env(:serviceradar_core, :crypto_secret, String.duplicate("a", 32))
    on_exit(fn -> restore_crypto_secret(previous_crypto_secret) end)

    actor = SystemActor.system(:onboarding_package_atomicity_test)
    unique = System.unique_integer([:positive])

    assert {:ok, created} =
             OnboardingPackages.create(
               %{
                 label: "Atomic delivery #{unique}",
                 component_id: "atomic-delivery-#{unique}",
                 component_type: :agent,
                 partition_id: "atomic-delivery-#{unique}"
               },
               actor: actor
             )

    package_uuid = Ecto.UUID.dump!(created.package.id)

    on_exit(fn ->
      Repo.query!(
        "DELETE FROM platform.oban_jobs WHERE args ->> 'package_id' = $1",
        [created.package.id]
      )

      Repo.query!(
        "DELETE FROM platform.edge_onboarding_events WHERE package_id = $1::uuid",
        [package_uuid]
      )

      Repo.query!(
        "DELETE FROM platform.edge_onboarding_packages WHERE package_id = $1::uuid",
        [package_uuid]
      )
    end)

    {:ok, actor: actor, created: created}
  end

  test "delivery compare-and-set rejects a token consumed after its pre-read", %{
    actor: actor,
    created: created
  } do
    parent = self()
    package_uuid = Ecto.UUID.dump!(created.package.id)

    locker =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!(
            """
            SELECT package_id
            FROM platform.edge_onboarding_packages
            WHERE package_id = $1::uuid
            FOR UPDATE
            """,
            [package_uuid]
          )

          send(parent, {:package_locked, self()})

          receive do
            :consume_when_delivery_blocks ->
              await_blocked_delivery_update!()

              Repo.query!(
                """
                UPDATE platform.edge_onboarding_packages
                SET download_token_consumed_at = now() AT TIME ZONE 'utc'
                WHERE package_id = $1::uuid
                """,
                [package_uuid]
              )
          after
            10_000 -> Repo.rollback(:lock_release_timeout)
          end
        end)
      end)

    assert_receive {:package_locked, locker_pid}, 5_000

    delivery =
      Task.async(fn ->
        result =
          OnboardingPackages.deliver(created.package.id, created.download_token, actor: actor)

        send(locker_pid, {:delivery_finished, delivery_outcome(result)})
        result
      end)

    try do
      send(locker_pid, :consume_when_delivery_blocks)

      assert {:ok, %Postgrex.Result{num_rows: 1}} = Task.await(locker, 15_000)
      assert {:error, :already_delivered} = Task.await(delivery, 15_000)
    after
      if Process.alive?(locker.pid), do: send(locker.pid, :consume_when_delivery_blocks)
      if Process.alive?(delivery.pid), do: Task.shutdown(delivery, :brutal_kill)
      if Process.alive?(locker.pid), do: Task.shutdown(locker, :brutal_kill)
    end

    assert {:ok, package} = OnboardingPackages.get(created.package.id, actor: actor)
    assert package.status == :issued
    assert package.download_token_consumed_at

    assert [[0]] =
             Repo.query!(
               """
               SELECT count(*)
               FROM platform.oban_jobs
               WHERE args ->> 'package_id' = $1
                 AND args ->> 'event_type' = 'delivered'
               """,
               [created.package.id]
             ).rows
  end

  defp await_blocked_delivery_update! do
    deadline = System.monotonic_time(:millisecond) + 10_000
    do_await_blocked_delivery_update!(deadline)
  end

  defp do_await_blocked_delivery_update!(deadline) do
    receive do
      {:delivery_finished, outcome} ->
        flunk("delivery finished before reaching the locked UPDATE: #{inspect(outcome)}")
    after
      0 -> :ok
    end

    # PostgreSQL caches statistics-view snapshots within a transaction. Clear that cache so
    # each poll can observe a delivery UPDATE that began after the preceding query.
    Repo.query!("SELECT pg_stat_clear_snapshot()")

    [[blocked_updates]] =
      Repo.query!("""
      SELECT count(*)
      FROM pg_stat_activity
      WHERE datname = current_database()
        AND pid <> pg_backend_pid()
        AND state = 'active'
        AND wait_event_type = 'Lock'
        AND query ILIKE '%UPDATE%'
        AND query ILIKE '%edge_onboarding_packages%'
      """).rows

    cond do
      blocked_updates > 0 ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("delivery UPDATE did not block on the held onboarding-package row lock")

      true ->
        receive do
        after
          10 -> do_await_blocked_delivery_update!(deadline)
        end
    end
  end

  defp delivery_outcome({:ok, _delivery}), do: :unexpected_success
  defp delivery_outcome({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp delivery_outcome({:error, _reason}), do: :error

  defp restore_crypto_secret(nil), do: Application.delete_env(:serviceradar_core, :crypto_secret)

  defp restore_crypto_secret(secret),
    do: Application.put_env(:serviceradar_core, :crypto_secret, secret)
end
