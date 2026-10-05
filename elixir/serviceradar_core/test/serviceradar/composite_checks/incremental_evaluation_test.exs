defmodule ServiceRadar.CompositeChecks.IncrementalEvaluationTest do
  @moduledoc """
  The incremental pass, the two evaluation marks, and the one-job-per-check
  schedule. Timestamps on input rows are moved explicitly with SQL: the
  two-minute watermark slack would otherwise make every row written during the
  test look dirty, and the selectivity these tests pin would be invisible.
  """

  use ServiceRadar.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.CompositeCheckRule
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadar.CompositeChecks.Evaluation
  alias ServiceRadar.CompositeChecks.EvaluationWorker
  alias ServiceRadar.CompositeChecks.RuleGenerator
  alias ServiceRadar.CompositeChecks.Scope
  alias ServiceRadar.CompositeChecks.TickWorker
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadar.Repo

  defp actor, do: SystemActor.system(:composite_check_test)

  defmodule ScopeRunner do
    @moduledoc false

    # The scope selects exactly the uids in the process dictionary, both for
    # the full pass's paged stream and for the incremental page filter.
    def query_page(_query, _opts) do
      uids = Process.get(:scope_uids, [])
      {:ok, %{rows: Enum.map(uids, &%{"uid" => &1}), next_cursor: nil}}
    end
  end

  defmodule FailingRunner do
    @moduledoc false
    def query_page(_query, _opts), do: {:error, :boom}
  end

  defp device!(uid) do
    Device
    |> Ash.Changeset.for_create(:create, %{uid: uid, hostname: uid})
    |> Ash.create!(actor: actor())
  end

  defp availability!(device_uid, agent_id, is_available) do
    DeviceAgentAvailability
    |> Ash.Changeset.for_create(
      :create,
      %{
        device_uid: device_uid,
        agent_id: agent_id,
        is_available: is_available,
        checked_at: DateTime.utc_now()
      },
      actor: actor()
    )
    |> Ash.create!()
  end

  # What the sweep ingestor does for a re-swept device: a new observation whose
  # updated_at is the database clock at the writing statement.
  defp resweep!(device_uid, agent_id, is_available, updated_at_sql \\ "now() AT TIME ZONE 'utc'") do
    Repo.query!(
      """
      UPDATE platform.device_agent_availability
      SET is_available = $3, checked_at = now(), updated_at = #{updated_at_sql}
      WHERE device_uid = $1 AND agent_id = $2
      """,
      [device_uid, agent_id, is_available]
    )
  end

  defp backdate_inputs!(uids) do
    Repo.query!(
      """
      UPDATE platform.device_agent_availability
      SET updated_at = updated_at - interval '1 hour'
      WHERE device_uid = ANY($1)
      """,
      [uids]
    )
  end

  defp build_check(opts \\ []) do
    {:ok, check} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Incremental #{System.unique_integer([:positive])}",
          scope_query: "in:devices",
          evaluation_interval_seconds: Keyword.get(opts, :interval, 300)
        },
        actor: actor()
      )
      |> Ash.create()

    inputs =
      for {key, expected, position} <- [{"a", "available", 0}, {"b", "blocked", 1}] do
        CompositeCheckInput
        |> Ash.Changeset.for_create(
          :create,
          %{
            check_id: check.id,
            key: key,
            label: key,
            position: position,
            kind: :vantage_point,
            expected: expected,
            config: %{"agent_id" => "agent-#{key}", "max_age_seconds" => 900}
          },
          actor: actor()
        )
        |> Ash.create!()
      end

    inputs =
      if Keyword.get(opts, :with_fact, false) do
        fact =
          CompositeCheckInput
          |> Ash.Changeset.for_create(
            :create,
            %{
              check_id: check.id,
              key: "nac",
              label: "nac",
              position: 2,
              kind: :device_metadata,
              config: %{"path" => "nac_applied", "value_type" => "boolean"}
            },
            actor: actor()
          )
          |> Ash.create!()

        inputs ++ [fact]
      else
        inputs
      end

    for attrs <- RuleGenerator.generate(inputs) do
      CompositeCheckRule
      |> Ash.Changeset.for_create(:create, Map.put(attrs, :check_id, check.id), actor: actor())
      |> Ash.create!()
    end

    {reload!(check), inputs}
  end

  defp reload!(check) do
    {:ok, check} = CompositeCheck.get_by_id(check.id, actor: actor())
    check
  end

  defp opts(extra \\ []), do: Keyword.merge([actor: actor(), runner: ScopeRunner], extra)

  defp result(check, uid),
    do: DeviceCompositeCheckResult.get_by_device_check(uid, check.id, actor: actor())

  # Moves the incremental mark to now, as if an incremental pass had just run.
  defp mark_now!(check) do
    {:ok, check} =
      CompositeCheck.record_pass(check, %{last_incremental_at: Evaluation.db_now()},
        actor: actor()
      )

    check
  end

  defp evaluation_jobs(check) do
    Repo.all(
      from(j in Oban.Job,
        where:
          j.worker == "ServiceRadar.CompositeChecks.EvaluationWorker" and
            fragment("? ->> 'check_id' = ?", j.args, ^to_string(check.id)),
        select: j.state
      )
    )
  end

  setup do
    uids = ["inc-1", "inc-2"]
    Process.put(:scope_uids, uids)

    for uid <- uids do
      device!(uid)
      availability!(uid, "agent-a", true)
      availability!(uid, "agent-b", false)
    end

    {check, inputs} = build_check()
    {:ok, _} = Evaluation.run_full(check, opts())

    %{check: reload!(check), inputs: inputs, uids: uids}
  end

  describe "incremental pass" do
    test "evaluates only devices whose inputs changed after the lagged mark", ctx do
      backdate_inputs!(ctx.uids)
      check = mark_now!(ctx.check)
      {:ok, untouched_before} = result(check, "inc-2")

      resweep!("inc-1", "agent-b", true)

      assert {:ok, summary} = Evaluation.run_incremental(check, opts())
      assert summary.evaluated == 1
      assert [%{device_uid: "inc-1", from_verdict: "isolated_verified"}] = summary.transitions

      # Without the timestamp filter inc-2 would be evaluated too and its
      # evaluated_at would move.
      assert {:ok, untouched_after} = result(check, "inc-2")
      assert untouched_after.evaluated_at == untouched_before.evaluated_at
      assert {:ok, %{verdict: verdict}} = result(check, "inc-1")
      assert verdict != "isolated_verified"
    end

    test "advances last_incremental_at to the pre-read now() and never last_evaluated_at", ctx do
      backdate_inputs!(ctx.uids)
      check = mark_now!(ctx.check)
      before = Evaluation.db_now()

      assert {:ok, %{evaluated: 0}} = Evaluation.run_incremental(check, opts())

      after_pass = reload!(check)
      assert DateTime.compare(after_pass.last_incremental_at, before) != :lt
      assert DateTime.compare(after_pass.last_incremental_at, Evaluation.db_now()) != :gt
      assert after_pass.last_evaluated_at == check.last_evaluated_at
    end

    test "a writer that opened inside the slack and committed after the read is selected next",
         ctx do
      backdate_inputs!(ctx.uids)
      check = mark_now!(ctx.check)
      {:ok, before} = result(check, "inc-1")

      # This pass reads, finds nothing, and stores its pre-read now() as the mark.
      assert {:ok, %{evaluated: 0}} = Evaluation.run_incremental(check, opts())
      check = reload!(check)

      # A writer whose transaction opened a minute before that mark commits only
      # now: its row carries updated_at one minute before the mark.
      resweep!(
        "inc-1",
        "agent-b",
        false,
        String.replace(
          "(CAST($3 AS timestamptz) AT TIME ZONE 'utc') - interval '60 seconds'",
          "$3",
          "'#{DateTime.to_iso8601(check.last_incremental_at)}'"
        )
      )

      assert {:ok, %{evaluated: 1, transitions: []}} = Evaluation.run_incremental(check, opts())

      # Same inputs, same verdict: re-evaluation inside the overlap is idempotent.
      assert {:ok, after_pass} = result(check, "inc-1")
      assert after_pass.verdict == before.verdict
      assert after_pass.changed_at == before.changed_at
    end

    test "a failed pass advances neither mark and the next pass selects the device again", ctx do
      backdate_inputs!(ctx.uids)
      check = mark_now!(ctx.check)
      resweep!("inc-1", "agent-b", true)

      assert {:error, _} = Evaluation.run_incremental(check, opts(runner: FailingRunner))

      unchanged = reload!(check)
      assert unchanged.last_incremental_at == check.last_incremental_at
      assert unchanged.last_evaluated_at == check.last_evaluated_at

      assert {:ok, %{evaluated: 1}} = Evaluation.run_incremental(unchanged, opts())
    end

    test "never sweeps result rows of devices outside the dirty set", ctx do
      backdate_inputs!(ctx.uids)
      check = mark_now!(ctx.check)
      Process.put(:scope_uids, ["inc-1"])

      assert {:ok, %{removed: 0}} = Evaluation.run_incremental(check, opts())
      assert {:ok, _} = result(check, "inc-2")
    end

    test "a device merged away after it was selected gets no row and no transition", ctx do
      backdate_inputs!(ctx.uids)
      check = mark_now!(ctx.check)
      resweep!("inc-1", "agent-b", true)
      {:ok, before} = result(check, "inc-1")

      Repo.query!(
        "UPDATE platform.ocsf_devices SET deleted_at = now(), deleted_reason = 'merged' WHERE uid = 'inc-1'"
      )

      assert {:ok, %{evaluated: 0, transitions: []}} = Evaluation.run_incremental(check, opts())
      assert {:ok, after_pass} = result(check, "inc-1")
      assert after_pass.evaluated_at == before.evaluated_at
      assert after_pass.verdict == before.verdict
    end

    test "a check with no mark has no incremental pass" do
      {check, _inputs} = build_check()
      assert is_nil(check.last_incremental_at)
      assert {:error, :no_incremental_mark} = Evaluation.run_incremental(check, opts())
    end
  end

  describe "metadata inputs" do
    setup ctx do
      {check, inputs} = build_check(with_fact: true)
      {:ok, _} = Evaluation.run_full(check, opts())
      backdate_inputs!(ctx.uids)
      check = mark_now!(reload!(check))

      since =
        DateTime.shift(check.last_incremental_at, second: -Evaluation.watermark_slack_seconds())

      %{fact_check: check, fact_inputs: inputs, since: since}
    end

    test "a fact write dirties the device through its provenance timestamp", ctx do
      {:ok, device} = Device.get_by_uid("inc-2", false, actor: actor())

      {:ok, _} =
        device
        |> Ash.Changeset.for_update(:write_facts, %{facts: %{"nac_applied" => true}},
          actor: actor()
        )
        |> Ash.update()

      assert Evaluation.dirty_uids(ctx.fact_check, ctx.fact_inputs, ctx.since) == [["inc-2"]]
    end

    test "set_availability and sweep status writes do not dirty the device", ctx do
      {:ok, device} = Device.get_by_uid("inc-2", false, actor: actor())

      {:ok, _} =
        device
        |> Ash.Changeset.for_update(:set_availability, %{is_available: false}, actor: actor())
        |> Ash.update()

      Repo.query!(
        "UPDATE platform.ocsf_devices SET modified_time = now(), last_seen_time = now() WHERE uid = 'inc-2'"
      )

      assert Evaluation.dirty_uids(ctx.fact_check, ctx.fact_inputs, ctx.since) == []
    end
  end

  describe "full pass" do
    test "a nil incremental mark runs the full pass, which stamps both marks even for an empty scope" do
      {check, _inputs} = build_check()
      assert EvaluationWorker.pass_for(check, Evaluation.db_now()) == :full

      Process.put(:scope_uids, [])
      before = Evaluation.db_now()
      assert {:ok, %{evaluated: 0}} = Evaluation.run_full(check, opts())

      check = reload!(check)
      assert DateTime.compare(check.last_incremental_at, before) != :lt
      assert DateTime.compare(check.last_evaluated_at, check.last_incremental_at) != :lt
      assert EvaluationWorker.pass_for(check, Evaluation.db_now()) == :incremental
    end

    test "a failed full pass advances neither mark", ctx do
      assert_raise RuntimeError, ~r/scope query failed/, fn ->
        Evaluation.run_full(ctx.check, opts(runner: FailingRunner))
      end

      unchanged = reload!(ctx.check)
      assert unchanged.last_incremental_at == ctx.check.last_incremental_at
      assert unchanged.last_evaluated_at == ctx.check.last_evaluated_at
    end

    test "the interval is measured from completion, so a long pass is not due on the next tick",
         ctx do
      check = ctx.check
      completed = check.last_evaluated_at

      assert EvaluationWorker.pass_for(check, DateTime.shift(completed, second: 30)) ==
               :incremental

      assert EvaluationWorker.pass_for(
               check,
               DateTime.shift(completed, second: check.evaluation_interval_seconds)
             ) == :full
    end

    test "incremental ticks do not move the full-pass clock, so the full pass stays due", ctx do
      stale =
        DateTime.shift(Evaluation.db_now(), second: -2 * ctx.check.evaluation_interval_seconds)

      {:ok, check} =
        CompositeCheck.record_pass(ctx.check, %{last_evaluated_at: stale}, actor: actor())

      assert {:ok, _} = Evaluation.run_incremental(check, opts())
      check = reload!(check)

      assert check.last_evaluated_at == stale
      assert EvaluationWorker.pass_for(check, Evaluation.db_now()) == :full
    end

    test "writes a page with a bounded number of statements", ctx do
      uids = for n <- 1..60, do: "inc-page-#{n}"

      for uid <- uids do
        device!(uid)
        availability!(uid, "agent-a", true)
        availability!(uid, "agent-b", false)
      end

      Process.put(:scope_uids, uids)
      handler = "incremental-evaluation-statement-count-#{System.unique_integer([:positive])}"
      counter = :counters.new(1, [])

      :telemetry.attach(
        handler,
        [:service_radar, :repo, :query],
        fn _event, _measurements, _metadata, _config -> :counters.add(counter, 1, 1) end,
        nil
      )

      try do
        assert {:ok, %{evaluated: 60}} = Evaluation.run(ctx.check, opts(emit_events?: false))
      after
        :telemetry.detach(handler)
      end

      # Load inputs, rules, live devices, availability, prior results, one
      # upsert and the sweep: a small constant, not one statement per device.
      assert :counters.get(counter, 1) <= 12

      for uid <- uids do
        assert {:ok, %{verdict: "isolated_verified", status: status}} = result(ctx.check, uid)
        assert status in [:healthy, :degraded, :down, :unknown]
      end
    end
  end

  describe "scope page" do
    test "a full 200-uid page of in-scope devices comes back whole through SRQL" do
      prefix = "incscope#{System.unique_integer([:positive])}"
      uids = for n <- 1..Scope.dirty_page_limit(), do: "#{prefix}-#{n}"
      Enum.each(uids, &device!/1)

      {:ok, normalized} = Scope.normalize("in:devices uid:%#{prefix}%")
      assert {:ok, in_scope} = Scope.contains?(normalized, uids)
      assert MapSet.size(in_scope) == Scope.dirty_page_limit()
    end
  end

  describe "schedule" do
    test "a tick inserts one job per enabled check and nothing while one is in flight", ctx do
      {:ok, enabled} =
        ctx.check
        |> Ash.Changeset.for_update(:enable, %{acknowledge_coverage_gap: true}, actor: actor())
        |> Ash.update()

      # Enabling inserted the first job; a tick and a save while it waits add nothing.
      assert evaluation_jobs(enabled) == ["available"]
      assert {:ok, _} = TickWorker.perform(%Oban.Job{})

      {:ok, _} =
        enabled
        |> Ash.Changeset.for_update(:update, %{description: "saved mid-pass"}, actor: actor())
        |> Ash.update()

      assert evaluation_jobs(enabled) == ["available"]

      # While it executes, the tick still inserts nothing.
      Repo.update_all(
        from(j in Oban.Job, where: j.worker == "ServiceRadar.CompositeChecks.EvaluationWorker"),
        set: [state: "executing"]
      )

      assert {:ok, _} = TickWorker.perform(%Oban.Job{})
      assert evaluation_jobs(enabled) == ["executing"]

      # After it completes, the next tick inserts exactly one.
      Repo.update_all(
        from(j in Oban.Job, where: j.worker == "ServiceRadar.CompositeChecks.EvaluationWorker"),
        set: [state: "completed"]
      )

      assert {:ok, _} = TickWorker.perform(%Oban.Job{})
      assert Enum.sort(evaluation_jobs(enabled)) == ["available", "completed"]
    end

    test "an evaluation job never inserts its own successor", ctx do
      {:ok, enabled} =
        ctx.check
        |> Ash.Changeset.for_update(:enable, %{acknowledge_coverage_gap: true}, actor: actor())
        |> Ash.update()

      Repo.update_all(
        from(j in Oban.Job, where: j.worker == "ServiceRadar.CompositeChecks.EvaluationWorker"),
        set: [state: "completed"]
      )

      assert {:ok, _} = EvaluationWorker.perform(%Oban.Job{args: %{"check_id" => enabled.id}})
      assert evaluation_jobs(enabled) == ["completed"]
    end
  end
end
