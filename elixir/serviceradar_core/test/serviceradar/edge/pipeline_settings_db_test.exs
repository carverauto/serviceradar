defmodule ServiceRadar.Edge.PipelineSettingsDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Edge.PipelineSetting
  alias ServiceRadar.Edge.PipelineSettings
  alias ServiceRadar.Repo

  @moduletag :integration

  @day 86_400
  @mib 1024 * 1024

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

  test "a deployment with no rows runs on the defaults", ctx do
    assert {:ok, %{horizon_seconds: 7 * @day, spool_max_bytes: 1024 * @mib}} ==
             PipelineSettings.resolve(ctx.agent, ctx.partition)
  end

  test "an operator lowers one agent's budget and other agents keep the wider one", ctx do
    put!(ctx.admin, :partition, ctx.partition, horizon_seconds: 2 * @day)
    put!(ctx.admin, :agent, ctx.agent, spool_max_bytes: 256 * @mib)

    assert {:ok, %{horizon_seconds: 2 * @day, spool_max_bytes: 256 * @mib}} ==
             PipelineSettings.resolve(ctx.agent, ctx.partition)

    assert {:ok, %{horizon_seconds: 2 * @day, spool_max_bytes: 1024 * @mib}} ==
             PipelineSettings.resolve("other-#{ctx.agent}", ctx.partition)

    # An agent whose partition has no row still gets its own and the global settings.
    assert {:ok, %{horizon_seconds: 7 * @day, spool_max_bytes: 256 * @mib}} ==
             PipelineSettings.resolve(ctx.agent, nil)
  end

  # The only test that writes the global row, so concurrent tests never wait on it.
  test "the global row's maximum caps every horizon and its budget is inherited", ctx do
    put!(ctx.admin, :global, "", max_horizon_seconds: 3 * @day, spool_max_bytes: 512 * @mib)
    put!(ctx.admin, :agent, ctx.agent, horizon_seconds: 20 * @day)

    assert {:ok, %{horizon_seconds: 3 * @day, spool_max_bytes: 512 * @mib}} ==
             PipelineSettings.resolve(ctx.agent, ctx.partition)
  end

  test "saving a scope again replaces its values in place", ctx do
    first = put!(ctx.admin, :partition, ctx.partition, horizon_seconds: @day)

    second =
      put!(ctx.admin, :partition, ctx.partition,
        horizon_seconds: 4 * @day,
        spool_max_bytes: 64 * @mib
      )

    assert first.id == second.id
    assert %{rows: [[1]]} = count(ctx.partition)

    assert {:ok, %{horizon_seconds: 4 * @day, spool_max_bytes: 64 * @mib}} ==
             PipelineSettings.resolve(ctx.agent, ctx.partition)
  end

  test "only an administrator can change a setting", ctx do
    assert {:error, %Ash.Error.Forbidden{}} =
             PipelineSetting
             |> Ash.Changeset.for_create(
               :upsert,
               %{scope: :partition, scope_key: ctx.partition, spool_max_bytes: 64 * @mib},
               actor: ctx.operator
             )
             |> Ash.create()

    assert %{rows: [[0]]} = count(ctx.partition)
  end

  test "the database refuses rows that would resolve ambiguously or starve the spool", ctx do
    insert = fn scope, key, horizon, max, spool ->
      Repo.query(
        """
        INSERT INTO platform.edge_pipeline_settings
          (scope, scope_key, horizon_seconds, max_horizon_seconds, spool_max_bytes)
        VALUES ($1, $2, $3, $4, $5)
        """,
        [scope, key, horizon, max, spool]
      )
    end

    # A global row has no key and every other scope needs one.
    assert {:error, %{postgres: %{code: :check_violation}}} =
             insert.("global", ctx.partition, nil, nil, nil)

    assert {:error, %{postgres: %{code: :check_violation}}} = insert.("agent", "", nil, nil, nil)
    # The maximum belongs to the global row only.
    assert {:error, %{postgres: %{code: :check_violation}}} =
             insert.("agent", ctx.agent, nil, @day, nil)

    # A horizon must be positive, and a scope must be one of the three.
    assert {:error, %{postgres: %{code: :check_violation}}} =
             insert.("agent", ctx.agent, 0, nil, nil)

    assert {:error, %{postgres: %{code: :check_violation}}} =
             insert.("site", ctx.agent, nil, nil, nil)

    # A spool budget leaves room above the agent spool's recovery reserve.
    assert {:error, %{postgres: %{code: :check_violation}}} =
             insert.("agent", ctx.agent, nil, nil, 16 * @mib - 1)

    assert {:ok, _} = insert.("agent", ctx.agent, nil, nil, 16 * @mib)
  end

  defp put!(actor, scope, scope_key, attrs) do
    assert {:ok, row} =
             PipelineSetting
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
      Repo.query("SELECT count(*) FROM platform.edge_pipeline_settings WHERE scope_key = $1", [
        scope_key
      ])

    result
  end
end
