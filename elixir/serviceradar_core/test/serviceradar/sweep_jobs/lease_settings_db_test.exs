defmodule ServiceRadar.SweepJobs.LeaseSettingsDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.LeaseSettings
  alias ServiceRadar.SweepJobs.SweepLeaseSetting

  @moduletag :integration

  @day 86_400

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    admin = %{id: Ash.UUID.generate(), email: "admin-#{suffix}@example.test", role: :admin}

    operator = %{
      id: Ash.UUID.generate(),
      email: "operator-#{suffix}@example.test",
      role: :operator
    }

    {:ok, admin: admin, operator: operator, agent: "agent-#{suffix}", partition: "part-#{suffix}"}
  end

  test "nothing is leased until an operator turns it on", ctx do
    assert {:ok, %{enabled?: false, horizon_seconds: 604_800}} =
             LeaseSettings.resolve(ctx.agent, ctx.partition)
  end

  test "an agent row overrides its partition row, and other agents keep the partition value",
       ctx do
    put!(ctx.admin, :partition, ctx.partition, leasing_enabled: true, horizon_seconds: 2 * @day)
    put!(ctx.admin, :agent, ctx.agent, horizon_seconds: 21 * @day)

    assert {:ok, %{enabled?: true, horizon_seconds: 21 * @day}} ==
             LeaseSettings.resolve(ctx.agent, ctx.partition)

    assert {:ok, %{enabled?: true, horizon_seconds: 2 * @day}} ==
             LeaseSettings.resolve("other-#{ctx.agent}", ctx.partition)

    assert {:ok, %{enabled?: false}} = LeaseSettings.resolve(ctx.agent, "other-#{ctx.partition}")
  end

  test "the global row's maximum caps every horizon and its switch is inherited", ctx do
    put!(ctx.admin, :global, "", leasing_enabled: true, max_horizon_seconds: 3 * @day)
    put!(ctx.admin, :agent, ctx.agent, horizon_seconds: 20 * @day)

    assert {:ok, %{enabled?: true, horizon_seconds: 3 * @day}} ==
             LeaseSettings.resolve(ctx.agent, ctx.partition)
  end

  test "saving a scope again replaces its values in place", ctx do
    first =
      put!(ctx.admin, :partition, ctx.partition, leasing_enabled: true, horizon_seconds: @day)

    second =
      put!(ctx.admin, :partition, ctx.partition,
        leasing_enabled: false,
        horizon_seconds: 4 * @day
      )

    assert first.id == second.id
    assert %{rows: [[1]]} = count(ctx.partition)

    assert {:ok, %{enabled?: false, horizon_seconds: 4 * @day}} ==
             LeaseSettings.resolve(ctx.agent, ctx.partition)
  end

  test "only an administrator can change a setting", ctx do
    assert {:error, %Ash.Error.Forbidden{}} =
             SweepLeaseSetting
             |> Ash.Changeset.for_create(
               :upsert,
               %{scope: :partition, scope_key: ctx.partition, leasing_enabled: true},
               actor: ctx.operator
             )
             |> Ash.create()

    assert %{rows: [[0]]} = count(ctx.partition)
  end

  test "the database refuses rows that would resolve ambiguously", ctx do
    insert = fn scope, key, horizon, max ->
      Repo.query(
        """
        INSERT INTO platform.sweep_lease_settings (scope, scope_key, horizon_seconds, max_horizon_seconds)
        VALUES ($1, $2, $3, $4)
        """,
        [scope, key, horizon, max]
      )
    end

    # A global row has no key and every other scope needs one.
    assert {:error, %{postgres: %{code: :check_violation}}} =
             insert.("global", ctx.partition, nil, nil)

    assert {:error, %{postgres: %{code: :check_violation}}} = insert.("agent", "", nil, nil)
    # The maximum belongs to the global row only.
    assert {:error, %{postgres: %{code: :check_violation}}} =
             insert.("agent", ctx.agent, nil, @day)

    # A horizon must be positive, and a scope must be one of the three.
    assert {:error, %{postgres: %{code: :check_violation}}} = insert.("agent", ctx.agent, 0, nil)
    assert {:error, %{postgres: %{code: :check_violation}}} = insert.("site", ctx.agent, nil, nil)
  end

  defp put!(actor, scope, scope_key, attrs) do
    assert {:ok, row} =
             SweepLeaseSetting
             |> Ash.Changeset.for_create(
               :upsert,
               Map.merge(%{scope: scope, scope_key: scope_key}, Map.new(attrs)),
               actor: actor
             )
             |> Ash.create()

    row
  end

  defp count(scope_key) do
    {:ok, result} =
      Repo.query("SELECT count(*) FROM platform.sweep_lease_settings WHERE scope_key = $1", [
        scope_key
      ])

    result
  end
end
