defmodule ServiceRadar.Inventory.ExposureSnapshotScopesDbTest do
  @moduledoc """
  The scope-table contract of the single exposure snapshot publisher: one row
  per scope, oldest-first claims under a lease, backoff with a dead-letter cap,
  and upgrade backfill from the retired per-scope Oban fan-out.
  """

  use ServiceRadar.DataCase, async: false

  alias Ecto.Migration.Runner
  alias ServiceRadar.Inventory.ExposureSnapshotScopes, as: Scopes
  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.Migrations.AddExposureSnapshotScopes, as: ScopesMigration

  @moduletag :integration

  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20261111235445_add_exposure_snapshot_scopes.exs",
                    __DIR__
                  )
  @external_resource @migration_path
  Code.require_file(@migration_path)

  setup do
    [[scope_floor]] =
      Repo.query!("SELECT COALESCE(max(id), 0) FROM platform.exposure_snapshot_scopes").rows

    [[job_floor]] = Repo.query!("SELECT COALESCE(max(id), 0) FROM oban_jobs").rows

    on_exit(fn ->
      Repo.query!("DELETE FROM platform.exposure_snapshot_scopes WHERE id > $1", [scope_floor])
      Repo.query!("DELETE FROM oban_jobs WHERE id > $1", [job_floor])
    end)

    base = 9_100_000 + System.unique_integer([:positive, :monotonic])
    {:ok, base: base, scope_floor: scope_floor, job_floor: job_floor}
  end

  test "demand records one pending row per scope and dedupes repeats",
       %{base: base, scope_floor: floor} do
    assert :ok = Scopes.request(base)
    assert :ok = Scopes.request(base + 1)
    assert :ok = Scopes.request(nil)
    assert :ok = Scopes.request(base)

    assert Repo.query!(
             "SELECT scope_ord, status, attempts FROM platform.exposure_snapshot_scopes WHERE id > $1 ORDER BY scope_ord NULLS FIRST",
             [floor]
           ).rows == [[nil, "pending", 0], [base, "pending", 0], [base + 1, "pending", 0]]
  end

  test "claims drain oldest-first and skip leased rows", %{base: base} do
    assert :ok = Scopes.request(base)
    assert :ok = Scopes.request(base + 1)
    assert :ok = Scopes.request(base + 2)

    assert {:ok, %{scope_ord: ^base}} = Scopes.claim(job_id())
    assert {:ok, %{scope_ord: scope}} = Scopes.claim(job_id())
    assert scope == base + 1

    # The leased rows are invisible to the next claim; the third row drains.
    assert {:ok, %{scope_ord: scope}} = Scopes.claim(job_id())
    assert scope == base + 2
    assert :none = Scopes.claim(job_id())
  end

  test "an expired lease hands the row to adoption, not to claim", %{base: base} do
    assert :ok = Scopes.request(base)
    assert {:ok, %{id: id}} = Scopes.claim(job_id())
    assert :none = Scopes.claim(job_id())

    Repo.query!(
      "UPDATE platform.exposure_snapshot_scopes SET lease_expires_at = now() - interval '1 second' WHERE id = $1",
      [id]
    )

    # Still publishing: only the publisher's adoption pre-pass may take it.
    assert :none = Scopes.claim(job_id())
    assert [[^id, ^base, nil]] = Scopes.expired_publishing()

    assert :ok = Scopes.requeue(id)
    assert {:ok, %{id: ^id}} = Scopes.claim(job_id())
  end

  test "a preparing row waits out its backoff, then drains", %{base: base} do
    assert :ok = Scopes.request(base)
    assert {:ok, %{id: id}} = Scopes.claim(job_id())
    assert :ok = Scopes.defer_preparing(id)
    assert :none = Scopes.claim(job_id())

    Repo.query!(
      "UPDATE platform.exposure_snapshot_scopes SET not_before = now() - interval '1 second' WHERE id = $1",
      [id]
    )

    assert {:ok, %{id: ^id}} = Scopes.claim(job_id())
  end

  test "completion retires the row from the drain", %{base: base} do
    assert :ok = Scopes.request(base)
    assert {:ok, %{id: id}} = Scopes.claim(job_id())
    assert :ok = Scopes.complete(id)
    assert :none = Scopes.claim(job_id())
    refute Scopes.pending?()
  end

  test "failures back off and the tenth dead-letters with telemetry", %{base: base} do
    handler = "scopes-dead-#{base}"
    test = self()

    :telemetry.attach_many(
      handler,
      [[:serviceradar, :exposure, :snapshot, :scope_dead]],
      fn event, measurements, metadata, _ ->
        send(test, {:scope_dead, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok = Scopes.request(base)
    assert {:ok, %{id: id}} = Scopes.claim(job_id())

    for _ <- 1..9 do
      assert {:failed, _} = Scopes.fail(id, :boom)
      assert :none = Scopes.claim(job_id())

      Repo.query!(
        "UPDATE platform.exposure_snapshot_scopes SET not_before = now() - interval '1 second' WHERE id = $1",
        [id]
      )
    end

    assert {:dead, 10} = Scopes.fail(id, :boom)
    assert_received {:scope_dead, _, %{attempts: 10}, %{scope_id: ^id}}

    assert [["dead"]] =
             Repo.query!("SELECT status FROM platform.exposure_snapshot_scopes WHERE id = $1", [
               id
             ]).rows
  end

  test "fresh demand revives a dead scope as a new obligation", %{base: base} do
    assert :ok = Scopes.request(base)
    assert {:ok, %{id: id}} = Scopes.claim(job_id())

    for _ <- 1..10, do: Scopes.fail(id, :boom)

    assert [["dead"]] =
             Repo.query!("SELECT status FROM platform.exposure_snapshot_scopes WHERE id = $1", [
               id
             ]).rows

    assert :ok = Scopes.request(base)

    assert [[^id, "pending", 0]] =
             Repo.query!(
               "SELECT id, status, attempts FROM platform.exposure_snapshot_scopes WHERE scope_ord = $1",
               [base]
             ).rows
  end

  test "release keeps the publishing row for adoption; requeue re-pends it", %{base: base} do
    assert :ok = Scopes.request(base)
    assert {:ok, %{id: id}} = Scopes.claim(job_id())

    assert :ok = Scopes.release(id)

    assert [[^id]] =
             Repo.query!(
               "SELECT id FROM platform.exposure_snapshot_scopes WHERE status = 'publishing' AND lease_expires_at < now()",
               []
             ).rows

    assert [[^id, ^base, nil]] = Scopes.expired_publishing()

    assert :ok = Scopes.requeue(id)
    assert {:ok, %{id: ^id}} = Scopes.claim(job_id())
  end

  test "a republish never adopts the previous attempt's generation", %{base: base} do
    previous_generation = base + 10

    assert :ok = Scopes.request(base)
    assert {:ok, %{id: id}} = Scopes.claim(job_id())
    assert :ok = Scopes.track_generation(id, previous_generation)
    assert :ok = Scopes.complete(id)

    assert :ok = Scopes.request(base)
    assert {:ok, %{id: ^id}} = Scopes.claim(job_id())
    assert :ok = Scopes.release(id)

    assert [[^id, ^base, nil]] = Scopes.expired_publishing()
  end

  test "ensure_publisher inserts one job no matter how often it runs", %{job_floor: floor} do
    assert :ok = Scopes.ensure_publisher()
    assert :ok = Scopes.ensure_publisher()

    assert [[1]] =
             Repo.query!(
               "SELECT count(*) FROM oban_jobs WHERE worker = 'ServiceRadar.Inventory.ExposureSnapshotPublisherWorker' AND state IN ('available', 'scheduled') AND id > $1",
               [floor]
             ).rows
  end

  test "pending? follows unrestored work", %{base: base} do
    refute Scopes.pending?()
    assert :ok = Scopes.request(base)
    assert Scopes.pending?()
    assert {:ok, %{id: id}} = Scopes.claim(job_id())
    assert Scopes.pending?()
    assert :ok = Scopes.complete(id)
    refute Scopes.pending?()
  end

  # Unboxed: the down/up cycle must persist the recreated table for the
  # sibling tests, which run in the same file in random order.
  @tag sandbox: :unboxed
  test "upgrade converts queued publisher demand into scope rows and deletes the jobs",
       %{base: base, job_floor: floor} do
    insert_legacy_job(%{"device_ord" => base}, "available")
    insert_legacy_job(%{"device_ord" => base}, "retryable")
    insert_legacy_job(%{"device_ord" => base + 1}, "scheduled")
    insert_legacy_job(%{}, "available")
    insert_legacy_job(%{"device_ord" => base + 2}, "executing")
    insert_legacy_job(%{"device_ord" => base + 3}, "discarded")
    insert_legacy_job(%{"device_ord" => base + 4}, "completed")

    migrate(:down)
    migrate(:up)

    assert Repo.query!(
             "SELECT scope_ord FROM platform.exposure_snapshot_scopes ORDER BY scope_ord NULLS FIRST",
             []
           ).rows == [[nil], [base], [base + 1]]

    # The converted jobs are gone; terminal and in-flight rows are untouched.
    assert Repo.query!(
             "SELECT count(*) FROM oban_jobs WHERE worker = 'ServiceRadar.Inventory.ExposureSnapshotWorker' AND id > $1",
             [floor]
           ).rows == [[3]]

    # The drop/create cycle restarts the identity sequence, so the shared
    # id-floor cleanup cannot see these rows: remove them by ordinal.
    Repo.query!(
      "DELETE FROM platform.exposure_snapshot_scopes WHERE scope_ord = $1 OR scope_ord = $2 OR scope_ord IS NULL",
      [base, base + 1]
    )
  end

  defp job_id, do: System.unique_integer([:positive, :monotonic])

  # Pass the map, not pre-encoded JSON: Postgrex encodes an Elixir map into a
  # jsonb object, while a pre-encoded string would be stored as a jsonb string
  # scalar whose ->>'device_ord' is NULL (which is exactly how the first
  # version of this helper silently collapsed every seed into the NULL scope).
  defp insert_legacy_job(args, state) do
    Repo.query!(
      """
      INSERT INTO platform.oban_jobs
        (queue, worker, args, errors, state, attempt, max_attempts, scheduled_at, inserted_at)
      VALUES
        ('maintenance', 'ServiceRadar.Inventory.ExposureSnapshotWorker', $1, '{}', $2, 0, 20, now(), now())
      """,
      [args, state]
    )
  end

  defp migrate(direction) do
    Runner.run(
      Repo,
      Repo.config(),
      20_261_111_235_445,
      ScopesMigration,
      :forward,
      direction,
      direction,
      log: false
    )
  end
end
