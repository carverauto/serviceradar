defmodule ServiceRadar.Notifications.EscalationTest do
  @moduledoc """
  Database-free tests for the escalation core (design D4, D6).

  `ServiceRadar.Notifications.Escalation` is a pure function over plain maps, so
  this file runs `async: true` with no `DataCase`, no application, and no
  database.

  The rule under the most pressure here is that `delay_seconds` is measured from
  the ALERT FIRE TIME and never from the previous step's dispatch, with exactly
  one exception: a snooze expiry rebases the origin. Both are asserted directly
  and repeatedly.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.Escalation

  @fire_time ~U[2026-08-11 12:00:00.000000Z]

  describe "plan/1 contract" do
    test "the evaluation instant is an input, not a clock read" do
      assert_raise ArgumentError, ~r/requires `:now`/, fn ->
        Escalation.plan(%{fire_time: @fire_time, steps: []})
      end
    end

    test "the fire time is required, because every delay is measured from it" do
      assert_raise ArgumentError, ~r/requires the alert fire time/, fn ->
        Escalation.plan(%{now: at(0), steps: []})
      end
    end

    test "the fire time falls back to the alert's own timestamps" do
      triggered = %{now: at(0), alert: %{status: :pending, triggered_at: @fire_time}, steps: []}
      created = %{now: at(0), alert: %{status: :pending, created_at: @fire_time}, steps: []}

      assert Escalation.delay_origin(triggered) == @fire_time
      assert Escalation.delay_origin(created) == @fire_time
    end

    test "the same context always yields the same plan" do
      context = context(steps: ladder(), now: at(400))

      assert Escalation.plan(context) == Escalation.plan(context)
    end

    test "an empty ladder plans nothing" do
      plan = Escalation.plan(context(steps: [], now: at(10_000)))

      assert plan.dispatches == []
      assert plan.withheld == []
      assert plan.next_due_at == nil
      assert plan.halted == nil
    end
  end

  describe "delay_seconds is measured from the alert fire time" do
    test "step 2 fires at fire_time + delay, not at step 1 dispatch + delay" do
      # design D4: step 1 dispatch completed 240s after the alert fired; step 2
      # carries delay_seconds: 300. Chaining off the dispatch would put step 2 at
      # t+540.
      plan = Escalation.plan(context(steps: ladder(), now: at(300)))

      assert {2, "pagerduty", due_at} = List.keyfind(plan.dispatches, 2, 0)
      assert due_at == at(300)
      refute Enum.any?(plan.dispatches, fn {_step, _channel, due} -> due == at(540) end)
    end

    test "a step is not due one second early" do
      plan = Escalation.plan(context(steps: ladder(), now: at(299)))

      assert step_numbers(plan.dispatches) == [1, 1]
      assert plan.next_due_at == at(300)
    end

    test "a step is due exactly at its offset" do
      plan = Escalation.plan(context(steps: ladder(), now: at(300)))

      assert step_numbers(plan.dispatches) == [1, 1, 2]
    end

    test "transport outcomes never accelerate the ladder" do
      # Every step 1 delivery failing inside the first 30 seconds must not make
      # step 2 due before its own offset. The planner has no input that could
      # express a transport failure, and the plan is identical whether or not
      # step 1 was already dispatched.
      without = Escalation.plan(context(steps: ladder(), now: at(30)))

      with_dispatched =
        Escalation.plan(
          context(
            steps: ladder(),
            now: at(30),
            dispatched: [{1, "slack", at(0)}, {1, "email", at(0)}]
          )
        )

      assert without.next_due_at == at(300)
      assert with_dispatched.next_due_at == at(300)
      assert with_dispatched.dispatches == []
    end

    test "late scheduler ticks still record the instant the rung was owed" do
      plan = Escalation.plan(context(steps: ladder(), now: at(4000)))

      assert plan.dispatches == [
               {1, "slack", at(0)},
               {1, "email", at(0)},
               {2, "pagerduty", at(300)},
               {3, "pagerduty-p1", at(900)},
               {3, "sms", at(900)}
             ]
    end
  end

  describe "the snooze-expiry exception" do
    test "an expired snooze rebases the remaining step delays" do
      # Spec scenario: step 2 at 300, step 3 at 900, snooze elapses at t+2000.
      expiry = at(2000)

      plan =
        Escalation.plan(
          context(
            steps: ladder(),
            now: at(2900),
            snooze_until: expiry,
            dispatched: [{1, "slack", at(0)}, {1, "email", at(0)}]
          )
        )

      assert plan.origin == expiry
      assert {2, "pagerduty", due_at} = List.keyfind(plan.dispatches, 2, 0)
      assert due_at == at(2300)
      assert {3, "pagerduty-p1", step_three} = List.keyfind(plan.dispatches, 3, 0)
      assert step_three == at(2900)
    end

    test "a step not yet due under the rebased origin stays pending" do
      plan =
        Escalation.plan(context(steps: ladder(), now: at(2299), snooze_until: at(2000)))

      assert step_numbers(plan.dispatches) == [1, 1]
      assert plan.next_due_at == at(2300)
    end

    test "an active snooze does not rebase; Suppression records :snoozed instead" do
      plan = Escalation.plan(context(steps: ladder(), now: at(400), snooze_until: at(5000)))

      assert plan.origin == @fire_time
      assert {2, "pagerduty", at_300} = List.keyfind(plan.dispatches, 2, 0)
      assert at_300 == at(300)
    end

    test "the boundary instant counts as expired" do
      assert Escalation.delay_origin(context(now: at(2000), snooze_until: at(2000))) == at(2000)
      assert Escalation.delay_origin(context(now: at(1999), snooze_until: at(2000))) == @fire_time
    end

    test "clearing the snooze returns the origin to the fire time" do
      # `update :unsnooze` and `update :acknowledge` both nil snooze_until, which
      # is an operator saying "resume now", not "wait out the deferral".
      assert Escalation.delay_origin(context(now: at(3000), snooze_until: nil)) == @fire_time

      assert Escalation.delay_origin(%{
               now: at(3000),
               fire_time: @fire_time,
               alert: %{status: :pending, snooze_until: nil}
             }) == @fire_time
    end

    test "the snooze expiry is read off the alert when not supplied explicitly" do
      context = %{
        now: at(2500),
        fire_time: @fire_time,
        alert: %{status: :pending, snooze_until: at(2000)}
      }

      assert Escalation.delay_origin(context) == at(2000)
    end

    test "no event other than a snooze expiry rebases the origin" do
      dispatched_late = context(steps: ladder(), now: at(1000), dispatched: [{1, "slack", at(0)}])

      assert Escalation.plan(dispatched_late).origin == @fire_time
      assert Escalation.plan(context(steps: ladder(), now: at(1000))).origin == @fire_time
    end

    test "a snooze expiry earlier than the fire time cannot pull a rung forward" do
      earlier = DateTime.add(@fire_time, -600, :second)

      assert Escalation.delay_origin(context(now: at(10), snooze_until: earlier)) == @fire_time
    end
  end

  describe "acknowledgement" do
    test ":if_unacknowledged rungs are withheld, not dropped" do
      plan = Escalation.plan(context(steps: ladder(), now: at(1000), acknowledged: true))

      assert plan.dispatches == []

      assert plan.withheld == [
               {:acknowledged, {1, "slack", at(0)}},
               {:acknowledged, {1, "email", at(0)}},
               {:acknowledged, {2, "pagerduty", at(300)}},
               {:acknowledged, {3, "pagerduty-p1", at(900)}},
               {:acknowledged, {3, "sms", at(900)}}
             ]
    end

    test ":always rungs still fire for an acknowledged alert" do
      steps = [
        step(1, 0, :if_unacknowledged, ["slack"]),
        step(2, 300, :always, ["ticketing"])
      ]

      plan = Escalation.plan(context(steps: steps, now: at(400), acknowledged: true))

      assert plan.dispatches == [{2, "ticketing", at(300)}]
      assert plan.withheld == [{:acknowledged, {1, "slack", at(0)}}]
    end

    test "acknowledgement is derived from the alert status" do
      acknowledged = %{
        now: at(400),
        fire_time: @fire_time,
        alert: %{status: :acknowledged},
        steps: ladder()
      }

      assert Escalation.plan(acknowledged).dispatches == []
      assert Escalation.plan(acknowledged).halted == :acknowledged
    end

    test "a reopened alert escalates again, because status is what is read" do
      # `update :reopen` leaves acknowledged_at populated, so a planner keying on
      # the timestamp would never escalate a reopened alert.
      reopened = %{
        now: at(400),
        fire_time: @fire_time,
        alert: %{status: :pending, acknowledged_at: at(100)},
        steps: ladder()
      }

      plan = Escalation.plan(reopened)

      assert step_numbers(plan.dispatches) == [1, 1, 2]
      assert plan.halted == nil
    end

    test "acknowledgement halts the ladder" do
      plan = Escalation.plan(context(steps: ladder(), now: at(1000), acknowledged: true))

      assert plan.halted == :acknowledged
    end

    test "a resolved alert plans nothing at all" do
      for status <- [:resolved, :suppressed] do
        plan =
          Escalation.plan(%{
            now: at(4000),
            fire_time: @fire_time,
            alert: %{status: status},
            steps: ladder()
          })

        assert plan.dispatches == []
        assert plan.withheld == []
        assert plan.next_due_at == nil
        assert plan.halted == :resolved
      end
    end
  end

  describe "fan-out across a channel set" do
    test "one step yields one dispatch per channel" do
      plan =
        Escalation.plan(context(steps: [step(1, 0, :if_unacknowledged, ~w(a b c))], now: at(0)))

      assert plan.dispatches == [{1, "a", at(0)}, {1, "b", at(0)}, {1, "c", at(0)}]
    end

    test "every dispatch in a fan-out set carries the same step number and due_at" do
      plan = Escalation.plan(context(steps: ladder(), now: at(1000)))

      step_three = Enum.filter(plan.dispatches, fn {step, _channel, _due} -> step == 3 end)

      assert length(step_three) == 2
      assert Enum.map(step_three, fn {_step, _channel, due} -> due end) == [at(900), at(900)]
    end

    test "channel order inside a step is preserved" do
      steps = [step(1, 0, :if_unacknowledged, ["zulu", "alpha", "mike"])]
      plan = Escalation.plan(context(steps: steps, now: at(0)))

      assert Enum.map(plan.dispatches, fn {_step, channel, _due} -> channel end) ==
               ["zulu", "alpha", "mike"]
    end

    test "a channel set supplied as loaded channel records is accepted" do
      steps = [
        %{
          step_number: 1,
          delay_seconds: 0,
          condition: :if_unacknowledged,
          channels: [%{id: "slack", name: "#noc"}, %{id: "email"}]
        }
      ]

      plan = Escalation.plan(context(steps: steps, now: at(0)))

      assert plan.dispatches == [{1, "slack", at(0)}, {1, "email", at(0)}]
    end

    test "a step with no channels is reported rather than silently doing nothing" do
      steps = [step(1, 0, :if_unacknowledged, []), step(2, 300, :if_unacknowledged, ["pd"])]
      plan = Escalation.plan(context(steps: steps, now: at(400)))

      assert plan.dispatches == [{2, "pd", at(300)}]
      assert %{code: :step_without_channels, step_number: 1} in plan.diagnostics
    end
  end

  describe "repeats" do
    test "no repeats are planned when repeat_count is zero or absent" do
      for policy <- [%{repeat_count: 0, repeat_interval_seconds: 900}, %{}, nil] do
        plan =
          Escalation.plan(context(steps: short_ladder(), now: at(100_000), policy: policy))

        assert plan.dispatches == [{1, "slack", at(0)}, {2, "pagerduty", at(300)}]
        assert plan.effective_repeat_interval_seconds == nil
      end
    end

    test "a repeat replays the whole ladder one interval after the previous cycle ends" do
      # ladder span 300, interval 900 -> cycle 1 origin at t+1200.
      policy = %{repeat_count: 2, repeat_interval_seconds: 900}
      plan = Escalation.plan(context(steps: short_ladder(), now: at(100_000), policy: policy))

      assert plan.dispatches == [
               {1, "slack", at(0)},
               {2, "pagerduty", at(300)},
               {1, "slack", at(1200)},
               {2, "pagerduty", at(1500)},
               {1, "slack", at(2400)},
               {2, "pagerduty", at(2700)}
             ]

      assert plan.effective_repeat_interval_seconds == 900
    end

    test "repeat cycles never overlap the ladder they replay" do
      # A ladder longer than the interval is exactly where anchoring cycles at
      # `origin + r * interval` would interleave replays and page more often
      # than either knob allows.
      policy = %{repeat_count: 1, repeat_interval_seconds: 60}
      plan = Escalation.plan(context(steps: ladder(), now: at(100_000), policy: policy))

      due = Enum.map(plan.dispatches, fn {_step, _channel, due} -> DateTime.to_unix(due) end)

      assert due == Enum.sort(due)
      assert {1, "slack", at(960)} in plan.dispatches
    end

    test "repeats are due on the clock, not all at once" do
      policy = %{repeat_count: 3, repeat_interval_seconds: 900}
      plan = Escalation.plan(context(steps: short_ladder(), now: at(1300), policy: policy))

      assert plan.dispatches == [
               {1, "slack", at(0)},
               {2, "pagerduty", at(300)},
               {1, "slack", at(1200)}
             ]

      assert plan.next_due_at == at(1500)
    end

    test "acknowledgement stops further repeats" do
      policy = %{repeat_count: 3, repeat_interval_seconds: 900}

      plan =
        Escalation.plan(
          context(steps: always_ladder(), now: at(100_000), policy: policy, acknowledged: true)
        )

      # Only cycle 0 survives: the repeat itself is the human-escalation
      # mechanism the acknowledgement answered.
      assert plan.dispatches == [{1, "slack", at(0)}, {2, "ticketing", at(300)}]
      assert plan.effective_repeat_interval_seconds == nil
      assert plan.halted == :acknowledged
    end

    test "repeat_count without an interval is reported and plans no repeats" do
      policy = %{repeat_count: 3, repeat_interval_seconds: nil}
      plan = Escalation.plan(context(steps: short_ladder(), now: at(100_000), policy: policy))

      assert plan.dispatches == [{1, "slack", at(0)}, {2, "pagerduty", at(300)}]
      assert %{code: :repeat_interval_missing, repeat_count: 3} in plan.diagnostics
    end
  end

  describe "the renotify cadence floor (C10)" do
    test "an interval below the rule floor is clamped up, never honoured" do
      policy = %{repeat_count: 1, repeat_interval_seconds: 900}

      plan =
        Escalation.plan(
          context(
            steps: short_ladder(),
            now: at(100_000),
            policy: policy,
            renotify_seconds: 21_600
          )
        )

      assert plan.effective_repeat_interval_seconds == 21_600

      assert %{
               code: :repeat_interval_clamped,
               configured_seconds: 900,
               floor_seconds: 21_600,
               effective_seconds: 21_600
             } in plan.diagnostics

      # Cycle 1 sits at ladder span 300 + floor 21600, not at 300 + 900.
      assert {1, "slack", at(21_900)} in plan.dispatches
      refute {1, "slack", at(1200)} in plan.dispatches
    end

    test "an interval at or above the floor is honoured with no diagnostic" do
      for interval <- [21_600, 43_200] do
        policy = %{repeat_count: 1, repeat_interval_seconds: interval}

        plan =
          Escalation.plan(
            context(
              steps: short_ladder(),
              now: at(200_000),
              policy: policy,
              renotify_seconds: 21_600
            )
          )

        assert plan.effective_repeat_interval_seconds == interval
        assert plan.diagnostics == []
      end
    end

    test "the floor may be read off the governing rule" do
      policy = %{repeat_count: 1, repeat_interval_seconds: 60}

      plan =
        Escalation.plan(
          context(
            steps: short_ladder(),
            now: at(100_000),
            policy: policy,
            rule: %{renotify_seconds: 3600}
          )
        )

      assert plan.effective_repeat_interval_seconds == 3600
    end

    test "an absent or nonsensical floor leaves the configured interval alone" do
      policy = %{repeat_count: 1, repeat_interval_seconds: 900}

      for floor <- [nil, 0, -1, "6h"] do
        plan =
          Escalation.plan(
            context(
              steps: short_ladder(),
              now: at(100_000),
              policy: policy,
              renotify_seconds: floor
            )
          )

        assert plan.effective_repeat_interval_seconds == 900
        assert plan.diagnostics == []
      end
    end

    test "the floor governs repeats, not the rungs inside one ladder" do
      policy = %{repeat_count: 0}

      plan =
        Escalation.plan(
          context(steps: ladder(), now: at(1000), policy: policy, renotify_seconds: 21_600)
        )

      assert step_numbers(plan.dispatches) == [1, 1, 2, 3, 3]
    end
  end

  describe "already-created dispatches" do
    test "are excluded so a scheduler tick does not double-page" do
      plan =
        Escalation.plan(
          context(
            steps: ladder(),
            now: at(1000),
            dispatched: [{1, "slack", at(0)}, {1, "email", at(0)}, {2, "pagerduty", at(300)}]
          )
        )

      assert plan.dispatches == [{3, "pagerduty-p1", at(900)}, {3, "sms", at(900)}]
    end

    test "are matched on the instant, not on DateTime struct equality" do
      # A timestamp read back from Postgres at :second precision does not `==`
      # the :microsecond one that produced it.
      second_precision = DateTime.truncate(at(300), :second)

      plan =
        Escalation.plan(
          context(
            steps: ladder(),
            now: at(400),
            dispatched: [
              {1, "slack", DateTime.truncate(at(0), :second)},
              {2, "pagerduty", second_precision}
            ]
          )
        )

      assert plan.dispatches == [{1, "email", at(0)}]
    end

    test "accept a MapSet as well as a list" do
      dispatched = MapSet.new([{1, "slack", at(0)}, {1, "email", at(0)}])
      plan = Escalation.plan(context(steps: ladder(), now: at(400), dispatched: dispatched))

      assert plan.dispatches == [{2, "pagerduty", at(300)}]
    end

    test "withheld decisions are re-emitted, because record_suppression collapses them" do
      # Design D5/C8: an identical repeat increments occurrence_count on the
      # existing row rather than inserting a duplicate, which is how an operator
      # sees both why and how often.
      context =
        context(
          steps: ladder(),
          now: at(1000),
          acknowledged: true,
          dispatched: [{1, "slack", at(0)}, {1, "email", at(0)}]
        )

      plan = Escalation.plan(context)

      assert {:acknowledged, {1, "slack", at(0)}} in plan.withheld
      assert length(plan.withheld) == 5
    end
  end

  describe "configuration diagnostics" do
    test "duplicate step numbers are reported" do
      steps = [step(1, 0, :if_unacknowledged, ["a"]), step(1, 300, :if_unacknowledged, ["b"])]
      plan = Escalation.plan(context(steps: steps, now: at(400)))

      assert %{code: :duplicate_step_number, step_number: 1, count: 2} in plan.diagnostics
      assert length(plan.dispatches) == 2
    end

    test "a later step with a shorter delay is reported" do
      steps = [step(1, 600, :if_unacknowledged, ["a"]), step(2, 60, :if_unacknowledged, ["b"])]
      plan = Escalation.plan(context(steps: steps, now: at(700)))

      assert %{
               code: :non_monotonic_delay,
               step_number: 2,
               delay_seconds: 60,
               previous_step_number: 1,
               previous_delay_seconds: 600
             } in plan.diagnostics
    end

    test "an unrecognised condition is reported and defaults to the safe one" do
      steps = [step(1, 0, :whenever, ["a"])]
      plan = Escalation.plan(context(steps: steps, now: at(10), acknowledged: true))

      assert %{code: :unknown_step_condition, step_number: 1, condition: :whenever} in plan.diagnostics

      assert plan.dispatches == []
      assert plan.withheld == [{:acknowledged, {1, "a", at(0)}}]
    end

    test "a well formed ladder produces no diagnostics" do
      assert Escalation.plan(context(steps: ladder(), now: at(1000))).diagnostics == []
    end

    test "malformed step entries are skipped rather than crashing the plan" do
      steps = [step(1, 0, :if_unacknowledged, ["a"]), %{delay_seconds: 60}, "not a step"]
      plan = Escalation.plan(context(steps: steps, now: at(100)))

      assert plan.dispatches == [{1, "a", at(0)}]
    end
  end

  describe "escalation is not retry and is not failover" do
    test "transport attributes in the context change nothing" do
      # design D4: retry lives on the delivery row (attempt_count,
      # next_attempt_at) and failover on the channel (fallback_channel_id,
      # fail_closed). Neither is an escalation input.
      plain = Escalation.plan(context(steps: ladder(), now: at(400)))

      noisy =
        [steps: ladder(), now: at(400)]
        |> context()
        |> Map.merge(%{
          attempt_count: 3,
          max_attempts: 3,
          next_attempt_at: at(60),
          fallback_channel_id: "fallback",
          fail_closed: true,
          last_error: "503 Service Unavailable"
        })
        |> Escalation.plan()

      assert plain == noisy
    end

    test "step attributes borrowed from the transport are ignored" do
      steps = [
        Map.merge(step(1, 0, :if_unacknowledged, ["slack"]), %{
          attempt_count: 5,
          max_attempts: 5,
          fallback_channel_id: "fallback"
        })
      ]

      plan = Escalation.plan(context(steps: steps, now: at(0)))

      assert plan.dispatches == [{1, "slack", at(0)}]
    end

    test "a fan-out sibling is never expressed as a retry or a failover hop" do
      plan = Escalation.plan(context(steps: ladder(), now: at(0)))

      assert plan.dispatches == [{1, "slack", at(0)}, {1, "email", at(0)}]
      assert Enum.uniq(step_numbers(plan.dispatches)) == [1]
    end
  end

  describe "next_due_at" do
    test "is the earliest rung still ahead" do
      plan = Escalation.plan(context(steps: ladder(), now: at(0)))

      assert plan.next_due_at == at(300)
    end

    test "is nil once the ladder is exhausted" do
      plan = Escalation.plan(context(steps: ladder(), now: at(100_000)))

      assert plan.next_due_at == nil
    end

    test "accounts for a rebased origin" do
      plan = Escalation.plan(context(steps: ladder(), now: at(2000), snooze_until: at(2000)))

      assert plan.next_due_at == at(2300)
    end
  end

  # --- Fixtures -------------------------------------------------------------

  defp at(offset_seconds), do: DateTime.add(@fire_time, offset_seconds, :second)

  defp context(overrides) do
    Enum.into(overrides, %{
      now: at(0),
      fire_time: @fire_time,
      alert: %{id: "alert-1", status: :pending},
      steps: []
    })
  end

  defp step(step_number, delay_seconds, condition, channel_ids) do
    %{
      step_number: step_number,
      delay_seconds: delay_seconds,
      condition: condition,
      channel_ids: channel_ids
    }
  end

  # Step 1 t+0 -> [Slack, Email]; step 2 t+5m -> [PagerDuty];
  # step 3 t+15m -> [PagerDuty P1, SMS]. The ladder from design D4.
  defp ladder do
    [
      step(1, 0, :if_unacknowledged, ["slack", "email"]),
      step(2, 300, :if_unacknowledged, ["pagerduty"]),
      step(3, 900, :if_unacknowledged, ["pagerduty-p1", "sms"])
    ]
  end

  defp short_ladder do
    [
      step(1, 0, :if_unacknowledged, ["slack"]),
      step(2, 300, :if_unacknowledged, ["pagerduty"])
    ]
  end

  defp always_ladder do
    [
      step(1, 0, :always, ["slack"]),
      step(2, 300, :always, ["ticketing"])
    ]
  end

  defp step_numbers(dispatches), do: Enum.map(dispatches, fn {step, _channel, _due} -> step end)
end
