defmodule ServiceRadar.TestSupportSandboxTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.EventRule
  alias ServiceRadar.Observability.LogPromotion
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration

  setup_all do
    TestSupport.start_core!(sandbox_owner?: false)

    assert_raise DBConnection.OwnershipError, fn ->
      Repo.query!("SELECT 1")
    end

    :ok
  end

  test "database owner rolls committed-looking state back between test scopes" do
    table = "sandbox_isolation_#{System.unique_integer([:positive])}"
    qualified_table = "platform.#{table}"

    TestSupport.with_repo_owner(%{async: false}, fn ->
      Repo.query!("CREATE TABLE #{qualified_table} (id integer PRIMARY KEY)")
      Repo.query!("INSERT INTO #{qualified_table} (id) VALUES (1)")

      assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM #{qualified_table}")
    end)

    TestSupport.with_repo_owner(%{async: false}, fn ->
      assert %{rows: [[nil]]} =
               Repo.query!("SELECT to_regclass($1::text)", [qualified_table])
    end)
  end

  test "async unboxed mode is rejected before pool mode changes" do
    assert_raise ArgumentError, ~r/async.*unboxed.*serial lane/s, fn ->
      TestSupport.checkout_repo!(%{async: true, sandbox: :unboxed})
    end

    assert_raise DBConnection.OwnershipError, fn -> Repo.query!("SELECT 1") end
  end

  test "async callers cannot start a shared helper owner" do
    assert_raise ArgumentError, ~r/shared owner.*async/s, fn ->
      TestSupport.with_repo_owner(%{async: true}, fn -> flunk("must not run") end)
    end

    assert_raise DBConnection.OwnershipError, fn -> Repo.query!("SELECT 1") end
  end

  test "stopping one non-shared owner leaves the other owner usable" do
    with_probe_table(fn qualified_table ->
      {runner_a, owner_a} = start_owner_runner()
      {runner_b, owner_b} = start_owner_runner()

      on_exit(fn ->
        stop_owner_runner(runner_a, owner_a)
        stop_owner_runner(runner_b, owner_b)
      end)

      assert %{num_rows: 1} =
               owner_runner_query(runner_a, "INSERT INTO #{qualified_table} (id) VALUES (1)")

      assert %{rows: [[0]]} =
               owner_runner_query(runner_b, "SELECT count(*) FROM #{qualified_table}")

      stop_owner_runner(runner_a, owner_a)

      assert %{num_rows: 1} =
               owner_runner_query(runner_b, "INSERT INTO #{qualified_table} (id) VALUES (2)")

      assert %{rows: [[1]]} =
               owner_runner_query(runner_b, "SELECT count(*) FROM #{qualified_table}")

      stop_owner_runner(runner_b, owner_b)
    end)
  end

  test "sandbox allowance accepts only successful results" do
    for accepted <- [:ok, {:already, :allowed}] do
      assert :ok = TestSupport.validate_sandbox_allowance!(accepted, self())
    end

    for rejected <- [{:already, :owner}, :not_found, {:unexpected, :shape}] do
      assert_raise ArgumentError, ~r/sandbox.*allow/i, fn ->
        TestSupport.validate_sandbox_allowance!(rejected, self())
      end
    end
  end

  test "allowed children see a parent transaction while another owner stays isolated" do
    with_probe_table(fn qualified_table ->
      TestSupport.with_repo_owner(%{async: false}, fn ->
        {child, child_ref} =
          spawn_monitor(fn ->
            receive do
              {:count_rows, parent, table} ->
                send(parent, {:child_rows, self(), Repo.query!("SELECT count(*) FROM #{table}")})
            end
          end)

        assert :ok = TestSupport.allow_sandbox(child)
        assert %{num_rows: 1} = Repo.query!("INSERT INTO #{qualified_table} (id) VALUES (1)")

        send(child, {:count_rows, self(), qualified_table})
        assert_receive {:child_rows, ^child, %{rows: [[1]]}}, 1_000
        assert_receive {:DOWN, ^child_ref, :process, ^child, :normal}, 1_000

        {other_owner, other_owner_ref} = start_owner_runner()

        try do
          assert %{rows: [[0]]} =
                   owner_runner_query(other_owner, "SELECT count(*) FROM #{qualified_table}")
        after
          stop_owner_runner(other_owner, other_owner_ref)
        end
      end)
    end)
  end

  test "long tests give sandbox rollback bounded teardown headroom" do
    assert TestSupport.sandbox_ownership_timeout(%{timeout: 1_800_000}) == 1_860_000
    assert is_nil(TestSupport.sandbox_ownership_timeout(%{timeout: 120_000}))
    assert is_nil(TestSupport.sandbox_ownership_timeout(%{}))
  end

  test "repository owner teardown drains shards started by log promotion" do
    previous_shards = Application.get_env(:serviceradar_core, :stateful_alert_engine_shards)
    Application.put_env(:serviceradar_core, :stateful_alert_engine_shards, 1)

    on_exit(fn ->
      case previous_shards do
        nil -> Application.delete_env(:serviceradar_core, :stateful_alert_engine_shards)
        value -> Application.put_env(:serviceradar_core, :stateful_alert_engine_shards, value)
      end
    end)

    {engine_pid, monitor_ref} =
      TestSupport.with_repo_owner(%{async: false}, fn ->
        actor = %{id: "system", role: :admin}
        subject = "logs.sandbox-lifecycle.#{System.unique_integer([:positive])}"

        {:ok, _rule} =
          EventRule
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "sandbox-lifecycle-#{Ash.UUID.generate()}",
              source_type: :log,
              source: %{},
              match: %{"subject_prefix" => subject},
              event: %{"log_name" => "test.sandbox.lifecycle", "alert" => false}
            },
            actor: actor
          )
          |> Ash.create()

        log = %{
          id: Ash.UUID.generate(),
          timestamp: DateTime.utc_now(),
          severity_text: "INFO",
          severity_number: 11,
          body: "sandbox lifecycle probe",
          service_name: "test",
          attributes: %{"serviceradar" => %{"ingest" => %{"subject" => subject}}},
          resource_attributes: %{},
          created_at: DateTime.utc_now()
        }

        assert {:ok, 1} = LogPromotion.promote([log])

        assert [{pid, _metadata}] = ProcessRegistry.lookup(:stateful_alert_engine)
        assert Process.alive?(pid)
        {pid, Process.monitor(pid)}
      end)

    assert_receive {:DOWN, ^monitor_ref, :process, ^engine_pid, _reason}, 1_000
    assert ProcessRegistry.lookup(:stateful_alert_engine) == []
  end

  defp with_probe_table(fun) do
    table = "sandbox_owner_probe_#{System.unique_integer([:positive])}"
    qualified_table = "platform.#{table}"

    TestSupport.checkout_repo!(%{sandbox: :unboxed})
    Repo.query!("CREATE TABLE #{qualified_table} (id integer PRIMARY KEY)")
    Sandbox.mode(Repo, :manual)

    try do
      fun.(qualified_table)
    after
      Sandbox.mode(Repo, :auto)
      Repo.query!("DROP TABLE IF EXISTS #{qualified_table}")
      Sandbox.mode(Repo, :manual)
    end
  end

  defp start_owner_runner do
    parent = self()

    runner =
      spawn(fn ->
        owner = Sandbox.start_owner!(Repo, shared: false)
        send(parent, {:owner_runner_started, self(), owner})
        owner_runner_loop(owner)
      end)

    assert_receive {:owner_runner_started, ^runner, owner}, 1_000
    {runner, owner}
  end

  defp owner_runner_loop(owner) do
    receive do
      {:query, parent, query} ->
        send(parent, {:owner_runner_query_result, self(), Repo.query!(query)})
        owner_runner_loop(owner)

      {:stop, parent} ->
        TestSupport.stop_repo_owner(owner, shared: false)
        send(parent, {:owner_runner_stopped, self(), owner})
    end
  end

  defp owner_runner_query(runner, query) do
    send(runner, {:query, self(), query})
    assert_receive {:owner_runner_query_result, ^runner, result}, 1_000
    result
  end

  defp stop_owner_runner(runner, owner) do
    ref = Process.monitor(runner)

    receive do
      {:DOWN, ^ref, :process, ^runner, :normal} ->
        :ok
    after
      0 ->
      send(runner, {:stop, self()})
      assert_receive {:owner_runner_stopped, ^runner, ^owner}, 1_000
      assert_receive {:DOWN, ^ref, :process, ^runner, :normal}, 1_000
    end
  end
end
