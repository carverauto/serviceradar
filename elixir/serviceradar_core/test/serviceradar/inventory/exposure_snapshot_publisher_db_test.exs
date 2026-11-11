defmodule ServiceRadar.Inventory.ExposureSnapshotPublisherDbTest do
  @moduledoc """
  The singleton publisher loop: quiet exits, never waiting on the session
  lock, and orphan adoption that completes finished generations without
  republishing while leaving live pipeline generations alone.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Inventory.ExposureSnapshotPublisherWorker, as: PublisherWorker
  alias ServiceRadar.Inventory.ExposureSnapshotScopes, as: Scopes
  alias ServiceRadar.Inventory.ExposureSnapshotState, as: State
  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.DirectSession

  @moduletag :integration

  setup do
    [[scope_floor]] =
      Repo.query!("SELECT COALESCE(max(id), 0) FROM platform.exposure_snapshot_scopes").rows

    [[job_floor]] = Repo.query!("SELECT COALESCE(max(id), 0) FROM oban_jobs").rows

    [[gen_floor]] =
      Repo.query!("SELECT COALESCE(max(id), 0) FROM platform.exposure_snapshot_generations").rows

    on_exit(fn ->
      Repo.query!("DELETE FROM platform.exposure_snapshot_scopes WHERE id > $1", [scope_floor])
      Repo.query!("DELETE FROM oban_jobs WHERE id > $1", [job_floor])

      Repo.query!("DELETE FROM platform.exposure_snapshot_generations WHERE id > $1", [
        gen_floor
      ])
    end)

    enable_warehouse!()

    base = 9_200_000 + System.unique_integer([:positive, :monotonic])
    {:ok, base: base}
  end

  @tag sandbox: :unboxed
  test "a quiet table drains immediately" do
    refute Scopes.pending?()
    assert :ok = PublisherWorker.perform(%Oban.Job{args: %{}})
  end

  @tag sandbox: :unboxed
  test "a held session lock exits quietly without touching scopes", %{base: base} do
    assert :ok = Scopes.request(base)

    holder =
      Task.async(fn ->
        DirectSession.run(fn session ->
          [[true]] = Postgrex.query!(session, "SELECT pg_try_advisory_lock(74526, 0)", []).rows
          Process.sleep(60_000)
        end)
      end)

    await_lock_held()

    try do
      assert :ok = PublisherWorker.perform(%Oban.Job{args: %{}})

      assert [[base, "pending", nil]] =
               Repo.query!(
                 "SELECT scope_ord, status, claimed_by FROM platform.exposure_snapshot_scopes WHERE scope_ord = $1",
                 [base]
               ).rows
    after
      Task.shutdown(holder, :brutal_kill)
    end
  end

  @tag sandbox: :unboxed
  test "an orphaned scope whose generation completed is marked complete", %{base: base} do
    generation = create_generation(base, "complete")

    [[id]] =
      Repo.query!(
        """
        INSERT INTO platform.exposure_snapshot_scopes
          (scope_ord, status, generation_id, claimed_by, lease_expires_at)
        VALUES ($1, 'publishing', $2, 12345, now() - interval '1 second')
        RETURNING id
        """,
        [base, generation]
      ).rows

    assert :ok = PublisherWorker.perform(%Oban.Job{args: %{}})

    assert [["complete"]] =
             Repo.query!("SELECT status FROM platform.exposure_snapshot_scopes WHERE id = $1", [
               id
             ]).rows
  end

  @tag sandbox: :unboxed
  test "an orphaned scope on a live pipeline generation is left alone", %{base: base} do
    generation = create_generation(base, "published")

    [[id]] =
      Repo.query!(
        """
        INSERT INTO platform.exposure_snapshot_scopes
          (scope_ord, status, generation_id, claimed_by, lease_expires_at)
        VALUES ($1, 'publishing', $2, 12345, now() - interval '1 second')
        RETURNING id
        """,
        [base, generation]
      ).rows

    assert :ok = PublisherWorker.perform(%Oban.Job{args: %{}})

    assert [["publishing"]] =
             Repo.query!("SELECT status FROM platform.exposure_snapshot_scopes WHERE id = $1", [
               id
             ]).rows

    assert {:ok, %{"status" => "published"}} = State.get(generation)
  end

  @tag sandbox: :unboxed
  test "a disabled warehouse exits without touching scopes", %{base: base} do
    Application.delete_env(:serviceradar_core, StarRocks)
    assert :ok = Scopes.request(base)
    assert :ok = PublisherWorker.perform(%Oban.Job{args: %{}})

    assert [["pending"]] =
             Repo.query!(
               "SELECT status FROM platform.exposure_snapshot_scopes WHERE scope_ord = $1",
               [base]
             ).rows
  end

  defp enable_warehouse! do
    previous = Application.get_env(:serviceradar_core, StarRocks, [])
    on_exit(fn -> Application.put_env(:serviceradar_core, StarRocks, previous) end)
    Application.put_env(:serviceradar_core, StarRocks, Keyword.put(previous, :enabled, true))
  end

  defp create_generation(scope, status) do
    owner = Ecto.UUID.generate()
    [[snapshot]] = Repo.query!("SELECT pg_current_snapshot()::text", []).rows

    {:ok, generation} =
      State.create(scope, snapshot, owner, System.system_time(:millisecond) + 30_000)

    {:ok, :ok} =
      State.change(generation["id"], fn current ->
        {:ok, Map.put(current, "status", status), :ok}
      end)

    generation["id"]
  end

  defp await_lock_held(attempts \\ 60) do
    [[held]] =
      Repo.query!(
        """
        SELECT EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory'
          AND granted AND classid::bigint = 74526 AND objid = 0 AND objsubid = 2)
        """,
        []
      ).rows

    cond do
      held ->
        :ok

      attempts <= 1 ->
        flunk("publisher session lock was never taken by the holder")

      true ->
        Process.sleep(250)
        await_lock_held(attempts - 1)
    end
  end
end
