defmodule ServiceRadar.SweepJobs.LeasePassWorkerDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.DirectSession
  alias ServiceRadar.SweepJobs.LeasePassWorker
  alias ServiceRadar.SweepJobs.ObanSupport
  alias ServiceRadar.TestSupport

  @moduletag :integration

  @worker "ServiceRadar.SweepJobs.LeasePassWorker"

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "ticks dedupe over pending states with no period" do
    # The insert-time contract Oban enforces: a pending tick conflicts forever, and an
    # `executing` row — orphan or live — never blocks a tick.
    assert %{period: :infinity, states: [:available, :scheduled]} =
             LeasePassWorker.new(%{}).changes.unique
  end

  test "the execution backstop is the provisional fifteen minutes" do
    assert LeasePassWorker.timeout_ms() == 15 * 60_000
    assert LeasePassWorker.timeout(%Oban.Job{}) == LeasePassWorker.timeout_ms()
  end

  test "an orphaned executing row is rescued to available without charging the attempt" do
    attempted_at =
      DateTime.shift(DateTime.utc_now(), minute: -10)

    job =
      %Oban.Job{}
      |> Ecto.Changeset.change(
        state: "executing",
        queue: "maintenance",
        worker: @worker,
        args: %{},
        attempt: 1,
        max_attempts: 1,
        inserted_at: attempted_at,
        scheduled_at: attempted_at,
        attempted_at: attempted_at
      )
      |> Repo.insert!(prefix: ObanSupport.prefix())

    assert {:ok, [rescued]} = LeasePassWorker.rescue_orphaned()

    assert %{id: id, worker: @worker, queue: "maintenance", attempt: 1, max_attempts: 2} =
             rescued

    assert id == job.id

    assert %{state: "available", max_attempts: 2, attempt: 1} =
             Repo.get!(Oban.Job, job.id, prefix: ObanSupport.prefix())
  end

  test "an executing row whose holder is alive is left alone" do
    attempted_at =
      DateTime.shift(DateTime.utc_now(), minute: -10)

    job =
      %Oban.Job{}
      |> Ecto.Changeset.change(
        state: "executing",
        queue: "maintenance",
        worker: @worker,
        args: %{},
        attempt: 1,
        max_attempts: 1,
        inserted_at: attempted_at,
        scheduled_at: attempted_at,
        attempted_at: attempted_at
      )
      |> Repo.insert!(prefix: ObanSupport.prefix())

    holder = start_pass_lock_holder()

    try do
      assert {:ok, []} = LeasePassWorker.rescue_orphaned()

      assert %{state: "executing"} = Repo.get!(Oban.Job, job.id, prefix: ObanSupport.prefix())
    after
      release_pass_lock_holder(holder)
    end
  end

  test "a violently killed holder releases the lock, so its row is rescued" do
    attempted_at =
      DateTime.shift(DateTime.utc_now(), minute: -10)

    job =
      %Oban.Job{}
      |> Ecto.Changeset.change(
        state: "executing",
        queue: "maintenance",
        worker: @worker,
        args: %{},
        attempt: 1,
        max_attempts: 1,
        inserted_at: attempted_at,
        scheduled_at: attempted_at,
        attempted_at: attempted_at
      )
      |> Repo.insert!(prefix: ObanSupport.prefix())

    holder = start_pass_lock_holder()
    kill_pass_lock_holder(holder)

    # The socket close that releases the lock races process death; poll until the
    # backend has let go.
    assert [_rescued] = await_rescue()

    assert %{state: "available"} = Repo.get!(Oban.Job, job.id, prefix: ObanSupport.prefix())
  end

  defp await_rescue(attempts \\ 20) do
    case LeasePassWorker.rescue_orphaned() do
      {:ok, [_ | _] = rescued} ->
        rescued

      {:ok, []} when attempts > 1 ->
        Process.sleep(250)
        await_rescue(attempts - 1)

      result ->
        flunk("expected an orphan rescue, got #{inspect(result)}")
    end
  end

  # A live run's proof: a dedicated direct session holding the pass advisory lock, taken
  # through the same `DirectSession` primitive the worker uses. The session is linked to
  # its holder, so killing the holder closes the socket and PostgreSQL releases the
  # lock — the same release a timeout kill gets.
  defp start_pass_lock_holder do
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        _ =
          DirectSession.run(fn session ->
            # `pg_advisory_lock` blocks until held and returns void.
            %Postgrex.Result{} =
              Postgrex.query!(session, "SELECT pg_advisory_lock(hashtextextended($1, 0))", [
                "sweep_lease_pass"
              ])

            send(parent, {ref, :locked})

            receive do
              {^ref, :stop} -> :ok
            end
          end)

        :ok
      end)

    receive do
      {^ref, :locked} -> {pid, ref}
    after
      10_000 -> flunk("the lock holder never took the pass lock")
    end
  end

  defp release_pass_lock_holder({pid, ref}) do
    monitor = Process.monitor(pid)
    send(pid, {ref, :stop})

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      10_000 -> flunk("the lock holder never released the pass lock")
    end
  end

  defp kill_pass_lock_holder({pid, _ref}) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      10_000 -> flunk("the lock holder never died")
    end
  end
end
