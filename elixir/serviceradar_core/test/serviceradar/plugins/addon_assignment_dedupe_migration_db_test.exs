defmodule ServiceRadar.Plugins.AddonAssignmentDedupeMigrationDbTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.Migrations.EnforceUniqueEnabledAddonAssignments, as: Migration

  @moduletag :integration
  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20261008124719_enforce_unique_enabled_addon_assignments.exs",
                    __DIR__
                  )
  @external_resource @migration_path
  Code.require_file(@migration_path)

  setup do
    # The serial fixture lane owns this rollback-only transaction, including DDL.
    Repo.query!("DROP INDEX platform.addon_assignments_one_enabled_per_agent_addon_index")
    addon_id = "dedupe-test-#{Ecto.UUID.generate()}"
    package_id = insert_package(addon_id, "1.0.0", "approved")
    %{addon_id: addon_id, package_id: package_id}
  end

  test "cleanup keeps the delivery winner, preserves rows and is idempotent", ctx do
    cases = [
      {"manual", {"manual", 100, 1}, {"profile", 1, 2}},
      {"priority", {"profile", 10, 1}, {"profile", 20, 2}},
      {"integer-priority", {"profile", 50, 1}, {"profile", "0", 2}},
      {"recency", {"profile", 100, 2}, {"profile", 100, 1}},
      {"policy", {"policy", 0, 2}, {"policy", 0, 1}}
    ]

    expected =
      Enum.map(cases, fn {name, winner, loser} ->
        uid = "agent-dedupe-#{name}-#{Ecto.UUID.generate()}"
        winner_id = insert_assignment(ctx, uid, winner)
        loser_id = insert_assignment(ctx, uid, loser)
        {uid, winner_id, loser_id}
      end)

    # An unavailable manual package is filtered before source precedence.
    unavailable = %{ctx | package_id: insert_package(ctx.addon_id, "2.0.0", "staged")}
    uid = "agent-dedupe-eligible-#{Ecto.UUID.generate()}"
    winner_id = insert_assignment(ctx, uid, {"profile", 100, 1})
    loser_id = insert_assignment(unavailable, uid, {"manual", 0, 2})
    expected = [{uid, winner_id, loser_id} | expected]

    tie_uid = "agent-dedupe-tie-#{Ecto.UUID.generate()}"

    [tie_winner, tie_loser] =
      Enum.sort(for _ <- 1..2, do: insert_assignment(ctx, tie_uid, {"profile", 100, 1}))

    expected = [{tie_uid, tie_winner, tie_loser} | expected]

    # Legacy denormalized keys must not conceal duplicates.
    Repo.query!(
      "UPDATE platform.addon_assignments SET addon_id = 'legacy-key' WHERE id = $1::text::uuid",
      [loser_id]
    )

    Enum.each(Migration.cleanup_statements(), &Repo.query!/1)
    assert_winners(expected, ctx.addon_id)

    Enum.each(Migration.cleanup_statements(), &Repo.query!/1)
    assert_winners(expected, ctx.addon_id)

    assert %{rows: []} =
             Repo.query!("""
             SELECT agent_uid, addon_id FROM platform.addon_assignments WHERE enabled
             GROUP BY agent_uid, addon_id HAVING count(*) > 1
             """)
  end

  test "cleanup refuses a shadowed assignment's paused rollout without changing assignments",
       ctx do
    uid = "agent-dedupe-rollout-#{Ecto.UUID.generate()}"
    winner_id = insert_assignment(ctx, uid, {"manual", 100, 1})
    loser_id = insert_assignment(ctx, uid, {"profile", 100, 2})

    %{rows: [[rollout_id]]} =
      Repo.query!(
        """
        INSERT INTO platform.addon_rollouts
          (addon_id, source_type, source_id, previous_package_id, candidate_package_id, state,
           inserted_at, updated_at)
        VALUES ($1, 'assignment', $2::text::uuid, $3::text::uuid, $3::text::uuid, 'paused',
                now(), now()) RETURNING id::text
        """,
        [ctx.addon_id, loser_id, ctx.package_id]
      )

    Repo.query!(
      """
      INSERT INTO platform.addon_rollout_targets
        (rollout_id, assignment_id, agent_uid, addon_id, source_type, source_id,
         previous_package_id, candidate_package_id, batch_index, state, inserted_at, updated_at)
      VALUES ($1::text::uuid, $2::text::uuid, $3, $4, 'assignment', $2::text::uuid,
              $5::text::uuid, $5::text::uuid, 0, 'succeeded', now(), now())
      """,
      [rollout_id, loser_id, uid, ctx.addon_id, ctx.package_id]
    )

    # Let the sandbox own the savepoint around the whole cleanup. Each query
    # outside a Repo transaction has its own sandbox savepoint, whose release
    # also releases a manually nested savepoint.
    assert_raise Postgrex.Error, ~r/Resolve active rollouts on shadowed add-on assignments/, fn ->
      Repo.transaction(fn ->
        Enum.each(Migration.cleanup_statements(), &Repo.query!/1)
      end)
    end

    assert %{rows: rows} =
             Repo.query!(
               "SELECT id::text, enabled FROM platform.addon_assignments WHERE agent_uid = $1",
               [uid]
             )

    assert Enum.sort(rows) == Enum.sort([[winner_id, true], [loser_id, true]])

    assert %{rows: [["paused"]]} =
             Repo.query!(
               "SELECT state FROM platform.addon_rollouts WHERE source_id = $1::text::uuid",
               [loser_id]
             )

    # A completed rollout's succeeded targets are history, not active owners.
    Repo.query!(
      "UPDATE platform.addon_rollouts SET state = 'completed' WHERE id = $1::text::uuid",
      [rollout_id]
    )

    Enum.each(Migration.cleanup_statements(), &Repo.query!/1)
    assert_winners([{uid, winner_id, loser_id}], ctx.addon_id)

    assert %{rows: [["succeeded"]]} =
             Repo.query!(
               "SELECT state FROM platform.addon_rollout_targets WHERE assignment_id = $1::text::uuid",
               [loser_id]
             )
  end

  defp assert_winners(expected, addon_id) do
    Enum.each(expected, fn {uid, winner_id, loser_id} ->
      assert %{rows: rows} =
               Repo.query!(
                 """
                 SELECT id::text, enabled, addon_id, params
                 FROM platform.addon_assignments WHERE agent_uid = $1
                 """,
                 [uid]
               )

      assert Enum.sort(rows) ==
               Enum.sort([
                 [winner_id, true, addon_id, %{"marker" => "preserved"}],
                 [loser_id, false, addon_id, %{"marker" => "preserved"}]
               ])
    end)
  end

  defp insert_package(addon_id, version, status) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO platform.addon_packages (addon_id, name, version, status)
        VALUES ($1, 'Synthetic dedupe package', $2, $3) RETURNING id::text
        """,
        [addon_id, version, status]
      )

    id
  end

  defp insert_assignment(ctx, uid, {source, priority, recency}) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO platform.addon_assignments
          (agent_uid, addon_id, addon_package_id, source, profile_metadata, params,
           inserted_at, updated_at)
        VALUES ($1, $2, $3::text::uuid, $4, $5::jsonb, '{"marker":"preserved"}',
                '2020-01-01'::timestamp, '2020-01-01'::timestamp + $6::integer * interval '1 second')
        RETURNING id::text
        """,
        [uid, ctx.addon_id, ctx.package_id, source, %{"priority" => priority}, recency]
      )

    id
  end
end
