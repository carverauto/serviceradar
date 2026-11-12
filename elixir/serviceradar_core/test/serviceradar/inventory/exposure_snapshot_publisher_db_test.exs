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
  alias ServiceRadar.Inventory.ExposureSnapshotWorker, as: Engine
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

  # A legacy row executed from the queue must not publish: its scope is owned
  # by the scopes table, so it completes immediately with no new generation.
  @tag sandbox: :unboxed
  test "a legacy queued row for a covered scope completes without publishing", %{base: base} do
    assert :ok = Scopes.request(base)

    [[before]] = Repo.query!("SELECT COUNT(*) FROM platform.exposure_snapshot_generations").rows

    assert :ok = Engine.perform(%Oban.Job{id: base, args: %{"device_ord" => base}})

    [[after_count]] =
      Repo.query!("SELECT COUNT(*) FROM platform.exposure_snapshot_generations").rows

    assert after_count == before

    assert [[id, "pending"]] =
             Repo.query!(
               "SELECT id, status FROM platform.exposure_snapshot_scopes WHERE scope_ord = $1",
               [base]
             ).rows

    assert is_integer(id)
  end

  # A legacy row for a scope with no row adopts it into the new model, then
  # completes; the publisher backstop drains it normally.
  @tag sandbox: :unboxed
  test "a legacy queued row for an unknown scope adopts it and completes", %{base: base} do
    assert [] =
             Repo.query!(
               "SELECT id FROM platform.exposure_snapshot_scopes WHERE scope_ord = $1",
               [
                 base
               ]
             ).rows

    assert :ok = Engine.perform(%Oban.Job{id: base, args: %{"device_ord" => base}})

    assert [[_id, "pending"]] =
             Repo.query!(
               "SELECT id, status FROM platform.exposure_snapshot_scopes WHERE scope_ord = $1",
               [base]
             ).rows
  end

  # Adopting never touches an existing row: a publishing scope keeps its
  # claim, generation, attempts, and error.
  @tag sandbox: :unboxed
  test "adopting a covered scope leaves its row untouched", %{base: base} do
    generation = create_generation(base, "publishing")

    [[id]] =
      Repo.query!(
        """
        INSERT INTO platform.exposure_snapshot_scopes
          (scope_ord, status, generation_id, attempts, error, claimed_by, lease_expires_at)
        VALUES ($1, 'publishing', $2, 3, 'not_connected', 12345, now() + interval '1 minute')
        RETURNING id
        """,
        [base, generation]
      ).rows

    assert :ok = Scopes.adopt_legacy(base)

    assert [[^id, "publishing", ^generation, 3, "not_connected", 12_345]] =
             Repo.query!(
               """
               SELECT id, status, generation_id, attempts, error, claimed_by
               FROM platform.exposure_snapshot_scopes WHERE scope_ord = $1
               """,
               [base]
             ).rows
  end

  # Old pods enqueue fleet-wide demand as `%{}` during the roll; executing it
  # must hand that demand to the publisher, not drop it.
  @tag sandbox: :unboxed
  test "a legacy queued row without device_ord adopts the fleet-wide scope" do
    Repo.query!("DELETE FROM platform.exposure_snapshot_scopes WHERE scope_ord IS NULL")

    assert :ok = Engine.perform(%Oban.Job{id: 1, args: %{}})

    assert [["pending"]] =
             Repo.query!(
               "SELECT status FROM platform.exposure_snapshot_scopes WHERE scope_ord IS NULL"
             ).rows
  end

  # A legacy row naming an invalid scope is terminal: nothing can adopt it.
  @tag sandbox: :unboxed
  test "a legacy queued row naming an invalid scope cancels" do
    [[before]] = Repo.query!("SELECT count(*) FROM platform.exposure_snapshot_scopes").rows

    for scope <- [0, -1, "7"] do
      assert {:cancel, :superseded} =
               Engine.perform(%Oban.Job{id: 1, args: %{"device_ord" => scope}})
    end

    assert [[^before]] =
             Repo.query!("SELECT count(*) FROM platform.exposure_snapshot_scopes").rows
  end

  # A scope whose generation already completed settles inline with no new
  # generation and a cleared error, instead of waiting for the tick.
  @tag sandbox: :unboxed
  test "settle completes a scope whose generation completed", %{base: base} do
    generation = create_generation(base, "complete")

    [[id]] =
      Repo.query!(
        """
        INSERT INTO platform.exposure_snapshot_scopes
          (scope_ord, status, generation_id, error, claimed_by, lease_expires_at)
        VALUES ($1, 'publishing', $2, 'not_connected', 12345, now() - interval '1 second')
        RETURNING id
        """,
        [base, generation]
      ).rows

    assert :done = PublisherWorker.settle_scope(id, generation)

    assert [[status, nil]] =
             Repo.query!(
               "SELECT status, error FROM platform.exposure_snapshot_scopes WHERE id = $1",
               [
                 id
               ]
             ).rows

    assert status == "complete"
  end

  # An aborted generation fails the scope through the same mapping as the
  # tick-driven path.
  @tag sandbox: :unboxed
  test "settle fails a scope whose generation aborted", %{base: base} do
    generation = create_generation(base, "aborted")

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

    assert :done = PublisherWorker.settle_scope(id, generation)

    assert [["failed"]] =
             Repo.query!("SELECT status FROM platform.exposure_snapshot_scopes WHERE id = $1", [
               id
             ]).rows
  end

  # A gap abort re-requests the fleet scope; settling must not leave that row
  # due now, or the same pass republishes it in a tight loop.
  @tag sandbox: :unboxed
  test "settle backs off the re-requested fleet scope after an abort" do
    Repo.query!("DELETE FROM platform.exposure_snapshot_scopes WHERE scope_ord IS NULL")
    generation = create_generation(nil, "aborted")

    [[id]] =
      Repo.query!(
        """
        INSERT INTO platform.exposure_snapshot_scopes
          (scope_ord, status, generation_id, claimed_by, lease_expires_at)
        VALUES (NULL, 'publishing', $1, 12345, now() + interval '1 minute')
        RETURNING id
        """,
        [generation]
      ).rows

    assert :ok = Scopes.request(nil)

    assert :done = PublisherWorker.settle_scope(id, generation)

    assert [["pending", true]] =
             Repo.query!(
               """
               SELECT status, not_before > now()
               FROM platform.exposure_snapshot_scopes WHERE id = $1
               """,
               [id]
             ).rows
  end

  # A generation still draining waits without touching the warehouse: the
  # scan runs only once receipts match the manifest.
  @tag sandbox: :unboxed
  test "settle waits on a generation that has not drained", %{base: base} do
    generation = create_generation(base, "finalizing")

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

    assert :wait = PublisherWorker.settle_scope(id, generation)

    assert [["publishing"]] =
             Repo.query!("SELECT status FROM platform.exposure_snapshot_scopes WHERE id = $1", [
               id
             ]).rows
  end

  # A drained generation whose scan fails (warehouse unreachable here) waits
  # instead of failing: the tick backstop converges it once StarRocks answers.
  @tag sandbox: :unboxed
  test "settle waits when the warehouse scan fails", %{base: base} do
    generation = create_drained_generation(base)

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

    assert :wait = PublisherWorker.settle_scope(id, generation)

    assert [["publishing", nil]] =
             Repo.query!(
               "SELECT status, error FROM platform.exposure_snapshot_scopes WHERE id = $1",
               [
                 id
               ]
             ).rows
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

  defp create_drained_generation(scope) do
    manifest = %{"0" => %{"page" => 1, "hash" => "00"}}

    owner = Ecto.UUID.generate()
    [[snapshot]] = Repo.query!("SELECT pg_current_snapshot()::text", []).rows

    {:ok, generation} =
      State.create(scope, snapshot, owner, System.system_time(:millisecond) + 30_000)

    {:ok, :ok} =
      State.change(generation["id"], fn current ->
        next =
          current
          |> Map.put("status", "finalizing")
          |> Map.put("receipts", manifest)
          |> Map.put("manifest", manifest)

        {:ok, next, :ok}
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
