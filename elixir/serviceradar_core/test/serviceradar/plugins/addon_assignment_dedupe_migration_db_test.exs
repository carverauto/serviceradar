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

  test "cleanup cancels active rollout work on shadowed assignments and keeps history", ctx do
    # A paused rollout sourced from the shadowed row, holding a succeeded target.
    uid = "agent-dedupe-rollout-#{Ecto.UUID.generate()}"
    winner_id = insert_assignment(ctx, uid, {"manual", 100, 1})
    loser_id = insert_assignment(ctx, uid, {"profile", 100, 2})
    sourced_id = insert_rollout(ctx, "assignment", loser_id, "paused")
    insert_target(ctx, sourced_id, loser_id, uid, "succeeded")

    # A running profile rollout whose override sits on another agent's shadowed
    # row, plus a target on an agent without duplicates.
    profile_uid = "agent-dedupe-profile-#{Ecto.UUID.generate()}"
    profile_winner = insert_assignment(ctx, profile_uid, {"manual", 100, 1})
    profile_loser = insert_assignment(ctx, profile_uid, {"profile", 100, 2})
    profile_rollout = insert_rollout(ctx, "profile", Ecto.UUID.generate(), "running")
    insert_target(ctx, profile_rollout, profile_loser, profile_uid, "waiting_health")

    Repo.query!(
      """
      UPDATE platform.addon_assignments
      SET rollout_id = $1::text::uuid, rollout_package_id = $2::text::uuid,
          rollout_started_at = now()
      WHERE id = $3::text::uuid
      """,
      [profile_rollout, ctx.package_id, profile_loser]
    )

    single_uid = "agent-dedupe-single-#{Ecto.UUID.generate()}"
    single_id = insert_assignment(ctx, single_uid, {"profile", 100, 1})
    insert_target(ctx, profile_rollout, single_id, single_uid, "pending")

    # A completed rollout's succeeded target is history, not an active owner.
    history_uid = "agent-dedupe-history-#{Ecto.UUID.generate()}"
    history_winner = insert_assignment(ctx, history_uid, {"manual", 100, 1})
    history_loser = insert_assignment(ctx, history_uid, {"profile", 100, 2})
    history_rollout = insert_rollout(ctx, "assignment", history_loser, "completed")
    insert_target(ctx, history_rollout, history_loser, history_uid, "succeeded")

    for _ <- 1..2, do: Enum.each(Migration.cleanup_statements(), &Repo.query!/1)

    assert_winners(
      [
        {uid, winner_id, loser_id},
        {profile_uid, profile_winner, profile_loser},
        {history_uid, history_winner, history_loser}
      ],
      ctx.addon_id
    )

    assert rollout(sourced_id) == ["canceled", "source_assignment_deduplicated"]
    assert rollout(profile_rollout) == ["running", nil]
    assert rollout(history_rollout) == ["completed", nil]

    assert target(sourced_id, loser_id) == ["canceled", "assignment_deduplicated"]
    assert target(profile_rollout, profile_loser) == ["canceled", "assignment_deduplicated"]
    assert target(profile_rollout, single_id) == ["pending", nil]
    assert target(history_rollout, history_loser) == ["succeeded", nil]

    assert %{rows: [[nil, nil, nil]]} =
             Repo.query!(
               """
               SELECT rollout_id, rollout_package_id, rollout_started_at
               FROM platform.addon_assignments WHERE id = $1::text::uuid
               """,
               [profile_loser]
             )
  end

  defp rollout(id) do
    %{rows: [row]} =
      Repo.query!(
        "SELECT state, blocked_reason FROM platform.addon_rollouts WHERE id = $1::text::uuid",
        [id]
      )

    row
  end

  defp target(rollout_id, assignment_id) do
    %{rows: [row]} =
      Repo.query!(
        """
        SELECT state, reason_code FROM platform.addon_rollout_targets
        WHERE rollout_id = $1::text::uuid AND assignment_id = $2::text::uuid
        """,
        [rollout_id, assignment_id]
      )

    row
  end

  defp insert_rollout(ctx, source_type, source_id, state) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO platform.addon_rollouts
          (addon_id, source_type, source_id, previous_package_id, candidate_package_id, state,
           inserted_at, updated_at)
        VALUES ($1, $2, $3::text::uuid, $4::text::uuid, $4::text::uuid, $5, now(), now())
        RETURNING id::text
        """,
        [ctx.addon_id, source_type, source_id, ctx.package_id, state]
      )

    id
  end

  defp insert_target(ctx, rollout_id, assignment_id, uid, state) do
    Repo.query!(
      """
      INSERT INTO platform.addon_rollout_targets
        (rollout_id, assignment_id, agent_uid, addon_id, source_type, source_id,
         previous_package_id, candidate_package_id, batch_index, state, inserted_at, updated_at)
      SELECT $1::text::uuid, $2::text::uuid, $3, $4, rollout.source_type, rollout.source_id,
             $5::text::uuid, $5::text::uuid, 0, $6, now(), now()
      FROM platform.addon_rollouts AS rollout WHERE rollout.id = $1::text::uuid
      """,
      [rollout_id, assignment_id, uid, ctx.addon_id, ctx.package_id, state]
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
