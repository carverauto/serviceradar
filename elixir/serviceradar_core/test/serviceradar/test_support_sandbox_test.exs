defmodule ServiceRadar.TestSupportSandboxTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.EventRule
  alias ServiceRadar.Observability.LogPromotion
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

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

    TestSupport.with_repo_owner(fn ->
      Repo.query!("CREATE TABLE #{qualified_table} (id integer PRIMARY KEY)")
      Repo.query!("INSERT INTO #{qualified_table} (id) VALUES (1)")

      assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM #{qualified_table}")
    end)

    TestSupport.with_repo_owner(fn ->
      assert %{rows: [[nil]]} =
               Repo.query!("SELECT to_regclass($1::text)", [qualified_table])
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
      TestSupport.with_repo_owner(fn ->
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
end
