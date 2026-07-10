defmodule ServiceRadar.TestSupportSandboxTest do
  use ExUnit.Case, async: false

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
end
