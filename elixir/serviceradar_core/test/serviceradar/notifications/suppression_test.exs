defmodule ServiceRadar.Notifications.SuppressionTest do
  @moduledoc """
  Database-free tests for the suppression core (design D5).

  `ServiceRadar.Notifications.Suppression` is a pure function over plain maps,
  so this whole file runs `async: true` with no `DataCase`, no application, and
  no database. That is the point of the decide-then-persist split: the hardest
  semantics in the notification platform are the cheapest ones to test.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.Suppression

  # 2026-08-11 is a Tuesday. Several schedule assertions depend on that.
  @now ~U[2026-08-11 14:00:00.000000Z]
  @past ~U[2026-08-11 10:00:00.000000Z]
  @future ~U[2026-08-11 18:00:00.000000Z]

  # Every reason except the reserved :dependency, in precedence order.
  @orderable Suppression.precedence() -- [:dependency]

  @alert_id "alert-1"
  @route_id "route-1"
  @policy_id "policy-1"
  @channel_id "channel-1"

  @business_hours %{
    "days" => ["mon", "tue", "wed", "thu", "fri"],
    "start_time" => "09:00",
    "end_time" => "17:00"
  }

  describe "the reason vocabulary" do
    test "is closed and enumerated in precedence order" do
      assert Suppression.reasons() == [
               :device_out_of_service,
               :silence,
               :schedule,
               :snoozed,
               :throttled,
               :acknowledged,
               :channel_disabled,
               :dependency,
               :no_matching_route
             ]
    end

    test "precedence is the reason list, so docs and behaviour cannot drift" do
      assert Suppression.precedence() == Suppression.reasons()
    end

    test "the reserved :dependency reason is excluded from what this change emits" do
      refute :dependency in Suppression.emittable_reasons()
      assert Suppression.emittable_reasons() == Suppression.reasons() -- [:dependency]
    end
  end

  describe "evaluate/1 contract" do
    test "a clean candidate dispatch is allowed" do
      assert Suppression.evaluate(base()) == :allow
    end

    test "the evaluation instant is an input, not a clock read" do
      assert_raise ArgumentError, ~r/requires `:now`/, fn ->
        Suppression.evaluate(%{alert: %{id: @alert_id}})
      end

      assert_raise ArgumentError, ~r/requires `:now`/, fn ->
        Suppression.evaluate(%{now: "2026-08-11T14:00:00Z"})
      end
    end

    test "the same context always yields the same outcome" do
      context = trigger(base(), :silence)

      assert Suppression.evaluate(context) == Suppression.evaluate(context)
      assert Suppression.evaluate(context) == Suppression.evaluate(context)
    end

    test "moving `now` forward changes the answer without changing anything else" do
      context = trigger(base(), :snoozed)

      assert {:suppress, :snoozed, _} = Suppression.evaluate(context)
      assert Suppression.evaluate(%{context | now: @future}) == :allow
    end
  end

  describe ":device_out_of_service" do
    test "an inactive subject device withholds the dispatch" do
      context = Map.put(base(), :device, %{id: "d1", device_uid: "dev-1", is_active: false})

      assert {:suppress, :device_out_of_service, detail} = Suppression.evaluate(context)
      assert detail.device_uid == "dev-1"
    end

    test "an active device does not suppress" do
      context = Map.put(base(), :device, %{device_uid: "dev-1", is_active: true})

      assert Suppression.evaluate(context) == :allow
    end

    test "a missing device fails open, because a false suppression is an unheard outage" do
      assert Suppression.evaluate(Map.put(base(), :device, nil)) == :allow
      assert Suppression.evaluate(base()) == :allow
    end

    test "the check is defence in depth for alerts created off the stateful engine" do
      # LogPromotion.update_alert_counts/2 and
      # TrivyReports.maybe_create_priority_alert/3 create alerts with no dedup
      # and no device-activity filter, so the notification layer re-checks
      # rather than trusting that the alert was already filtered.
      trivy_alert = %{id: @alert_id, status: :pending, device_uid: "dev-1"}

      context =
        base()
        |> Map.put(:alert, trivy_alert)
        |> Map.put(:device, %{is_active: false})

      assert {:suppress, :device_out_of_service, detail} = Suppression.evaluate(context)
      assert detail.device_uid == "dev-1"
    end

    test "device_out_of_service?/1 is exposed for callers" do
      assert Suppression.device_out_of_service?(%{is_active: false})
      refute Suppression.device_out_of_service?(%{is_active: true})
      refute Suppression.device_out_of_service?(nil)
    end
  end

  describe ":silence" do
    test "an active, in-window silence withholds the dispatch" do
      context = Map.put(base(), :silences, [silence()])

      assert {:suppress, :silence, detail} = Suppression.evaluate(context)
      assert detail.silence_id == "silence-1"
      assert detail.ends_at == @future
    end

    test "only the :active state suppresses" do
      for state <- [:scheduled, :expired, :cancelled] do
        context = Map.put(base(), :silences, [silence(%{state: state})])

        assert Suppression.evaluate(context) == :allow, "state #{state} must not suppress"
      end
    end

    test "a cancelled silence stops suppressing immediately, without waiting for ends_at" do
      context = Map.put(base(), :silences, [silence(%{state: :cancelled, ends_at: @future})])

      assert Suppression.evaluate(context) == :allow
    end

    test "the window is re-checked, so a lagging sweeper cannot extend a silence" do
      elapsed = silence(%{state: :active, ends_at: @past})

      assert Suppression.evaluate(Map.put(base(), :silences, [elapsed])) == :allow
    end

    test "the window start is inclusive and the window end is exclusive" do
      starting = silence(%{starts_at: @now, ends_at: @future})
      ending = silence(%{starts_at: @past, ends_at: @now})

      assert {:suppress, :silence, _} =
               Suppression.evaluate(Map.put(base(), :silences, [starting]))

      assert Suppression.evaluate(Map.put(base(), :silences, [ending])) == :allow
    end

    test "a silence that has not started yet does not suppress" do
      pending = silence(%{starts_at: @future, ends_at: ~U[2026-08-12 00:00:00.000000Z]})

      assert Suppression.evaluate(Map.put(base(), :silences, [pending])) == :allow
    end

    test "matchers are evaluated through the one shared grammar evaluator" do
      # `Router` asks the same question of the same document; a second matcher
      # implementation here is exactly what MatchExpression was unified to
      # prevent.
      matchers = %{"field" => "alert.severity", "equals" => "critical"}

      context =
        base()
        |> Map.put(:alert, %{id: @alert_id, status: :pending, severity: :critical})
        |> Map.put(:silences, [silence(%{matchers: matchers})])

      assert {:suppress, :silence, _} = Suppression.evaluate(context)

      non_matching = put_in(context, [:alert, :severity], :warning)
      assert Suppression.evaluate(non_matching) == :allow
    end

    test "an empty matcher document mutes everything, which is the documented capability" do
      context = Map.put(base(), :silences, [silence(%{matchers: %{}})])

      assert {:suppress, :silence, _} = Suppression.evaluate(context)
    end

    test "a matcher document that cannot be evaluated stops muting rather than muting all" do
      unevaluable = [
        %{"field" => "alert.severity"},
        %{"all" => "not a list"},
        %{"field" => "alert.severity", "matches" => "["}
      ]

      for matchers <- unevaluable do
        context = Map.put(base(), :silences, [silence(%{matchers: matchers})])

        assert Suppression.evaluate(context) == :allow,
               "#{inspect(matchers)} must not suppress"
      end
    end

    test "a caller that pre-narrowed its silence list may supply its own matcher" do
      context =
        base()
        |> Map.put(:silences, [
          silence(%{matchers: %{"field" => "alert.severity", "equals" => "critical"}})
        ])
        |> Map.put(:silence_matcher, fn _document, _subject -> true end)

      assert {:suppress, :silence, _} = Suppression.evaluate(context)

      never = Map.put(context, :silence_matcher, fn _document, _subject -> false end)
      assert Suppression.evaluate(never) == :allow
    end

    test "a richer match subject may be supplied by the caller" do
      matchers = %{"field" => "device.hostname", "equals" => "core-sw-1"}

      context =
        base()
        |> Map.put(:silences, [silence(%{matchers: matchers})])
        |> Map.put(:match_subject, %{
          "alert" => %{id: @alert_id},
          "device" => %{hostname: "core-sw-1"}
        })

      assert {:suppress, :silence, _} = Suppression.evaluate(context)
    end

    test "the first suppressing silence in caller order is the one recorded" do
      silences = [
        silence(%{id: "expired", state: :expired}),
        silence(%{id: "first-active"}),
        silence(%{id: "second-active"})
      ]

      assert {:suppress, :silence, detail} =
               Suppression.evaluate(Map.put(base(), :silences, silences))

      assert detail.silence_id == "first-active"
    end

    test "an empty or absent silence list allows" do
      assert Suppression.evaluate(Map.put(base(), :silences, [])) == :allow
      assert Suppression.evaluate(Map.put(base(), :silences, nil)) == :allow
    end
  end

  describe ":schedule in UTC" do
    test "inside an :active_within window the dispatch proceeds" do
      assert Suppression.evaluate(Map.put(base(), :schedule, schedule())) == :allow
      assert Suppression.schedule_active?(schedule(), @now) == {:ok, true}
    end

    test "outside an :active_within window the dispatch is withheld" do
      overnight = %{now: ~U[2026-08-11 02:00:00.000000Z]}
      context = base() |> Map.merge(overnight) |> Map.put(:schedule, schedule())

      assert {:suppress, :schedule, detail} = Suppression.evaluate(context)
      assert detail.schedule_id == "schedule-1"
      assert detail.timezone == "Etc/UTC"
      assert detail.mode == :active_within
    end

    test ":active_outside inverts the window set" do
      inverted = schedule(%{mode: :active_outside})

      assert {:suppress, :schedule, _} =
               Suppression.evaluate(Map.put(base(), :schedule, inverted))

      overnight = %{base() | now: ~U[2026-08-11 02:00:00.000000Z]}
      assert Suppression.evaluate(Map.put(overnight, :schedule, inverted)) == :allow
    end

    test "the day of week is honoured" do
      sunday_only = schedule(%{windows: [%{@business_hours | "days" => ["sun"]}]})

      assert Suppression.schedule_active?(sunday_only, @now) == {:ok, false}

      assert {:suppress, :schedule, _} =
               Suppression.evaluate(Map.put(base(), :schedule, sunday_only))
    end

    test "window start is inclusive and window end is exclusive" do
      assert Suppression.schedule_active?(schedule(), ~U[2026-08-11 09:00:00.000000Z]) ==
               {:ok, true}

      assert Suppression.schedule_active?(schedule(), ~U[2026-08-11 16:59:59.999999Z]) ==
               {:ok, true}

      assert Suppression.schedule_active?(schedule(), ~U[2026-08-11 17:00:00.000000Z]) ==
               {:ok, false}

      assert Suppression.schedule_active?(schedule(), ~U[2026-08-11 08:59:59.999999Z]) ==
               {:ok, false}
    end

    test "any window in the set may match" do
      split = schedule(%{windows: [%{@business_hours | "end_time" => "12:00"}, evening_window()]})

      assert Suppression.schedule_active?(split, ~U[2026-08-11 10:00:00.000000Z]) == {:ok, true}
      assert Suppression.schedule_active?(split, ~U[2026-08-11 14:00:00.000000Z]) == {:ok, false}
      assert Suppression.schedule_active?(split, ~U[2026-08-11 19:00:00.000000Z]) == {:ok, true}
    end

    test "windows are read with string keys, atom keys, day atoms, and Time structs" do
      atom_keyed =
        schedule(%{
          windows: [%{days: [:tue], start_time: ~T[09:00:00], end_time: ~T[17:00:00]}]
        })

      assert Suppression.schedule_active?(atom_keyed, @now) == {:ok, true}

      seconds_form = schedule(%{windows: [%{@business_hours | "start_time" => "09:00:00"}]})
      assert Suppression.schedule_active?(seconds_form, @now) == {:ok, true}
    end

    test "the UTC aliases resolve without a time zone database" do
      for zone <- ~w(UTC Etc/UTC utc etc/utc GMT Z Zulu) do
        assert Suppression.schedule_active?(schedule(%{timezone: zone}), @now) == {:ok, true},
               "zone #{zone} must resolve"
      end
    end

    test "a nil or disabled schedule never gates a route" do
      assert Suppression.schedule_active?(nil, @now) == {:ok, true}
      assert Suppression.evaluate(Map.put(base(), :schedule, nil)) == :allow

      disabled = schedule(%{enabled: false, windows: [%{@business_hours | "days" => ["sun"]}]})
      assert Suppression.schedule_active?(disabled, @now) == {:ok, true}
      assert Suppression.evaluate(Map.put(base(), :schedule, disabled)) == :allow
    end
  end

  describe "IANA schedule wall time" do
    test "the dispatcher-resolved local wall clock evaluates a non-UTC zone" do
      new_york = schedule(%{timezone: "America/New_York"})

      assert Suppression.schedule_active?(new_york, @now,
               local_datetime: ~N[2026-08-11 10:00:00.000000]
             ) == {:ok, true}

      assert Suppression.schedule_active?(new_york, ~U[2026-08-11 02:00:00.000000Z],
               local_datetime: ~N[2026-08-10 22:00:00.000000]
             ) == {:ok, false}
    end

    test "evaluate uses the resolved wall clock instead of failing open" do
      new_york = schedule(%{timezone: "America/New_York", mode: :active_within})
      overnight = %{base() | now: ~U[2026-08-11 02:00:00.000000Z]}

      context =
        overnight
        |> Map.put(:schedule, new_york)
        |> Map.put(:schedule_local_datetime, ~N[2026-08-10 22:00:00.000000])

      assert {:suppress, :schedule, %{timezone: "America/New_York"}} =
               Suppression.evaluate(context)
    end
  end

  describe ":schedule that cannot be evaluated" do
    # A schedule this evaluator cannot resolve must never be the thing that
    # silences a deployment: schedule_active?/2 reports the defect loudly and
    # evaluate/1 fails open. Save-time validation prevents this path for new
    # configuration; it remains defensive for legacy rows and database errors.

    test "an unresolved non-UTC zone remains an explicit typed error" do
      new_york = schedule(%{timezone: "America/New_York"})

      assert Suppression.schedule_active?(new_york, @now) ==
               {:error, {:unsupported_timezone, "America/New_York"}}
    end

    test "a schedule with no windows is an error and allows" do
      for windows <- [[], nil, "not a list"] do
        empty = schedule(%{windows: windows})

        assert Suppression.schedule_active?(empty, @now) == {:error, :no_windows}
        assert Suppression.evaluate(Map.put(base(), :schedule, empty)) == :allow
      end
    end

    test "a malformed window is reported by index and allows" do
      cases = [
        %{"days" => ["funday"], "start_time" => "09:00", "end_time" => "17:00"},
        %{"days" => [], "start_time" => "09:00", "end_time" => "17:00"},
        %{"start_time" => "09:00", "end_time" => "17:00"},
        %{"days" => ["tue"], "start_time" => "9:00", "end_time" => "17:00"},
        %{"days" => ["tue"], "start_time" => "09:00"},
        "not a map"
      ]

      for window <- cases do
        broken = schedule(%{windows: [window]})

        assert {:error, {:invalid_window, 0, message}} =
                 Suppression.schedule_active?(broken, @now)

        assert is_binary(message)
        assert Suppression.evaluate(Map.put(base(), :schedule, broken)) == :allow
      end
    end

    test "an unknown mode is an error and allows" do
      nonsense = schedule(%{mode: :active_sometimes})

      assert Suppression.schedule_active?(nonsense, @now) ==
               {:error, {:invalid_mode, :active_sometimes}}

      assert Suppression.evaluate(Map.put(base(), :schedule, nonsense)) == :allow
    end
  end

  describe ":snoozed is derived, not a state" do
    test "a future snooze on a live alert withholds the dispatch" do
      for status <- [:pending, :escalated] do
        context =
          put_in(base(), [:alert], %{id: @alert_id, status: status, snooze_until: @future})

        assert {:suppress, :snoozed, detail} = Suppression.evaluate(context)
        assert detail.snooze_until == @future
        assert detail.status == status
      end
    end

    test "an elapsed snooze no longer suppresses" do
      context = put_in(base(), [:alert], %{id: @alert_id, status: :pending, snooze_until: @past})

      assert Suppression.evaluate(context) == :allow
    end

    test "the snooze boundary is exclusive: snooze_until == now is already expired" do
      refute Suppression.snoozed?(%{status: :pending, snooze_until: @now}, @now)
      assert Suppression.snoozed?(%{status: :pending, snooze_until: @future}, @now)
    end

    test "snooze is meaningless outside the live statuses" do
      for status <- [:acknowledged, :resolved, :suppressed] do
        refute Suppression.snoozed?(%{status: status, snooze_until: @future}, @now)
      end
    end

    test "an alert with no snooze is not snoozed" do
      refute Suppression.snoozed?(%{status: :pending, snooze_until: nil}, @now)
      refute Suppression.snoozed?(%{status: :pending}, @now)
      refute Suppression.snoozed?(nil, @now)
    end
  end

  describe ":throttled" do
    test "a dispatch inside the route throttle window is withheld" do
      context =
        base()
        |> Map.put(:route, %{id: @route_id, throttle_seconds: 300})
        |> Map.put(:last_dispatch_at, DateTime.add(@now, -60, :second))

      assert {:suppress, :throttled, detail} = Suppression.evaluate(context)
      assert detail.throttle_seconds == 300
      assert detail.effective_seconds == 300
      assert detail.next_eligible_at == DateTime.add(@now, 240, :second)
    end

    test "a dispatch at the throttle boundary proceeds" do
      context =
        base()
        |> Map.put(:route, %{id: @route_id, throttle_seconds: 300})
        |> Map.put(:last_dispatch_at, DateTime.add(@now, -300, :second))

      assert Suppression.evaluate(context) == :allow
    end

    test "the rule cooldown is the floor: the longer of the two windows wins" do
      # Route narrows (lengthens) the cadence - accepted.
      route_longer =
        base()
        |> Map.put(:route, %{id: @route_id, throttle_seconds: 900})
        |> Map.put(:rule, %{cooldown_seconds: 600})
        |> Map.put(:last_dispatch_at, DateTime.add(@now, -700, :second))

      assert {:suppress, :throttled, detail} = Suppression.evaluate(route_longer)
      assert detail.effective_seconds == 900

      # Route tries to widen (shorten) the cadence - the rule floor still holds.
      route_shorter =
        base()
        |> Map.put(:route, %{id: @route_id, throttle_seconds: 300})
        |> Map.put(:rule, %{cooldown_seconds: 600})
        |> Map.put(:last_dispatch_at, DateTime.add(@now, -400, :second))

      assert {:suppress, :throttled, detail} = Suppression.evaluate(route_shorter)
      assert detail.effective_seconds == 600
      assert detail.cooldown_seconds == 600
      assert detail.throttle_seconds == 300
    end

    test "the rule cooldown alone throttles" do
      context =
        base()
        |> Map.put(:rule, %{cooldown_seconds: 600})
        |> Map.put(:last_dispatch_at, DateTime.add(@now, -120, :second))

      assert {:suppress, :throttled, detail} = Suppression.evaluate(context)
      assert detail.effective_seconds == 600
    end

    test "no prior dispatch and no configured window both allow" do
      configured = Map.put(base(), :route, %{id: @route_id, throttle_seconds: 300})
      assert Suppression.evaluate(configured) == :allow

      dispatched = Map.put(base(), :last_dispatch_at, DateTime.add(@now, -1, :second))
      assert Suppression.evaluate(dispatched) == :allow
    end

    test "an explicit throttle map wins over the route and rule" do
      context =
        base()
        |> Map.put(:route, %{id: @route_id, throttle_seconds: 30})
        |> Map.put(:throttle, %{
          throttle_seconds: 3600,
          last_dispatch_at: DateTime.add(@now, -60, :second)
        })

      assert {:suppress, :throttled, detail} = Suppression.evaluate(context)
      assert detail.effective_seconds == 3600
    end
  end

  describe ":acknowledged" do
    test "an :if_unacknowledged step is withheld once the alert is acknowledged" do
      context = acknowledged_context()

      assert {:suppress, :acknowledged, detail} = Suppression.evaluate(context)
      assert detail.condition == :if_unacknowledged
      assert detail.step_number == 1
    end

    test "an :always step still fires for an acknowledged alert" do
      context = put_in(acknowledged_context(), [:step, :condition], :always)

      assert Suppression.evaluate(context) == :allow
    end

    test "a missing step defaults to :if_unacknowledged, the safe condition" do
      context = Map.delete(acknowledged_context(), :step)

      assert {:suppress, :acknowledged, detail} = Suppression.evaluate(context)
      assert detail.condition == :if_unacknowledged
    end

    test "acknowledgement keys on status, never on acknowledged_at" do
      # `update :reopen` does not clear acknowledged_at, and `transition
      # :escalate` moves an acknowledged alert to :escalated while leaving it
      # populated. Keying on the timestamp would silence a reopened or escalated
      # alert forever.
      for status <- [:pending, :escalated] do
        reopened = %{
          id: @alert_id,
          status: status,
          acknowledged_at: @past,
          acknowledged_by: "someone"
        }

        context = Map.put(base(), :alert, reopened)

        assert Suppression.evaluate(context) == :allow
        refute Suppression.acknowledged?(reopened)
      end
    end

    test "acknowledged?/1 is exposed so the escalation core cannot disagree" do
      assert Suppression.acknowledged?(%{status: :acknowledged})
      refute Suppression.acknowledged?(%{status: :pending})
      refute Suppression.acknowledged?(nil)
    end
  end

  describe ":channel_disabled" do
    test "a disabled channel is recorded, not skipped silently" do
      context = put_in(base(), [:channel, :enabled], false)

      assert {:suppress, :channel_disabled, detail} = Suppression.evaluate(context)
      assert detail.channel_id == @channel_id
      assert detail.channel_enabled == false
    end

    test "a provider outside :active disables its channels" do
      for status <- [:draft, :disabled] do
        context = Map.put(base(), :provider, %{id: "provider-1", status: status})

        assert {:suppress, :channel_disabled, detail} = Suppression.evaluate(context)
        assert detail.provider_status == status
      end
    end

    test "an active provider allows" do
      assert Suppression.evaluate(Map.put(base(), :provider, %{status: :active})) == :allow
    end

    test "the provider may be reached through the channel" do
      context =
        base()
        |> Map.delete(:provider)
        |> Map.put(:channel, %{
          id: @channel_id,
          enabled: true,
          provider: %{status: :disabled}
        })

      assert {:suppress, :channel_disabled, _} = Suppression.evaluate(context)
    end

    test "an unknown provider and an absent channel both fail open" do
      assert Suppression.evaluate(Map.delete(base(), :provider)) == :allow
      assert Suppression.evaluate(Map.put(base(), :channel, nil)) == :allow
    end

    test "channel health alone never suppresses" do
      unhealthy = put_in(base(), [:channel, :enabled], true)
      unhealthy = put_in(unhealthy, [:channel, :health], :failing)

      assert Suppression.evaluate(unhealthy) == :allow
    end
  end

  describe ":no_matching_route" do
    test "an alert that matched zero enabled routes is recorded, never discarded" do
      context = Map.put(base(), :route, nil)

      assert Suppression.evaluate(context) == {:suppress, :no_matching_route, %{}}
    end

    test "an absent :route key is the same decision as an explicit nil" do
      assert Suppression.evaluate(Map.delete(base(), :route)) ==
               {:suppress, :no_matching_route, %{}}
    end
  end

  describe ":dependency is reserved" do
    test "it never fires, whatever the context says" do
      contexts = [
        base(),
        Map.put(base(), :route, nil),
        Map.put(base(), :dependency, %{parent_device_uid: "switch-1", parent_down: true}),
        Map.put(base(), :parent_device, %{is_active: false})
      ]

      for context <- contexts do
        refute match?({:suppress, :dependency, _}, Suppression.evaluate(context))
      end
    end

    test "it still holds its documented place in the precedence order" do
      assert Enum.at(Suppression.precedence(), 7) == :dependency
    end
  end

  describe "precedence between simultaneously true reasons" do
    # The first matching reason is the single value recorded on the delivery
    # row, so the order is contract, not accident. Every ordered pair is
    # asserted, except the one pair that cannot both hold - see below.
    for {higher, higher_index} <- Enum.with_index(@orderable),
        {lower, lower_index} <- Enum.with_index(@orderable),
        higher_index < lower_index,
        {higher, lower} != {:snoozed, :acknowledged} do
      test "#{higher} outranks #{lower}" do
        context =
          base()
          |> trigger(unquote(higher))
          |> trigger(unquote(lower))

        assert {:suppress, unquote(higher), _detail} = Suppression.evaluate(context)
      end
    end

    test ":snoozed and :acknowledged cannot both hold" do
      # Acknowledging nils snooze_until and moves status to :acknowledged, and
      # "snoozed" is derived as `status in [:pending, :escalated] and
      # snooze_until > now`. The pair is excluded from the matrix above because
      # the alert resource makes it unreachable, not because the order is
      # undefined.
      alert = %{id: @alert_id, status: :acknowledged, snooze_until: @future}

      refute Suppression.snoozed?(alert, @now)
      assert {:suppress, :acknowledged, _} = Suppression.evaluate(Map.put(base(), :alert, alert))
    end

    test "an inactive device outranks a route nobody configured" do
      # Both are true for a decommissioned device with no route. Reporting the
      # device is what ends the investigation: writing the route would not have
      # produced a page either.
      context =
        base()
        |> Map.put(:route, nil)
        |> Map.put(:device, %{device_uid: "dev-1", is_active: false})

      assert {:suppress, :device_out_of_service, _} = Suppression.evaluate(context)
    end
  end

  describe "re-evaluation at every dispatch" do
    test "a decision allowed at routing time is suppressed at dispatch time" do
      # design D5 property 1: the device is marked out of service between
      # routing and escalation step 2 fifteen minutes later.
      routing_context = base()
      assert Suppression.evaluate(routing_context) == :allow

      dispatch_context =
        routing_context
        |> Map.put(:now, DateTime.add(@now, 900, :second))
        |> Map.put(:device, %{device_uid: "dev-1", is_active: false})
        |> Map.put(:step, %{step_number: 2, condition: :if_unacknowledged})

      assert {:suppress, :device_out_of_service, _} = Suppression.evaluate(dispatch_context)
    end

    test "a silence created after routing suppresses the later retry" do
      assert Suppression.evaluate(base()) == :allow

      retry_context =
        base()
        |> Map.put(:now, DateTime.add(@now, 120, :second))
        |> Map.put(:silences, [silence()])

      assert {:suppress, :silence, _} = Suppression.evaluate(retry_context)
    end

    test "an expiring silence stops suppressing on the next evaluation" do
      context = Map.put(base(), :silences, [silence(%{ends_at: DateTime.add(@now, 60, :second)})])

      assert {:suppress, :silence, _} = Suppression.evaluate(context)
      assert Suppression.evaluate(%{context | now: DateTime.add(@now, 61, :second)}) == :allow
    end

    test "nothing is cached between calls" do
      allowed = base()
      suppressed = trigger(base(), :silence)

      assert Suppression.evaluate(allowed) == :allow
      assert {:suppress, :silence, _} = Suppression.evaluate(suppressed)
      assert Suppression.evaluate(allowed) == :allow
      assert {:suppress, :silence, _} = Suppression.evaluate(suppressed)
    end
  end

  describe "to_delivery_attributes/2" do
    test "an allowed dispatch has nothing to persist" do
      assert Suppression.to_delivery_attributes(:allow, base()) == :allow
    end

    test "a suppression carries the collapse identity tuple and the reason" do
      context = base() |> trigger(:silence) |> Map.put(:dedupe_key, "rule-1|device_id=abc")
      outcome = Suppression.evaluate(context)

      assert {:ok, attrs} = Suppression.to_delivery_attributes(outcome, context)

      assert attrs.alert_id == @alert_id
      assert attrs.policy_id == @policy_id
      assert attrs.step_number == 1
      assert attrs.channel_id == @channel_id
      assert attrs.dedupe_key == "rule-1|device_id=abc"
      assert attrs.suppression_reason == :silence
      assert attrs.route_id == @route_id
      assert attrs.execution_route == :control_plane
    end

    test "an unrouted decision carries null policy, step, and channel" do
      context =
        base()
        |> Map.put(:route, nil)
        |> Map.delete(:policy)
        |> Map.delete(:step)
        |> Map.delete(:channel)

      outcome = Suppression.evaluate(context)

      assert {:ok, attrs} = Suppression.to_delivery_attributes(outcome, context)
      assert attrs.suppression_reason == :no_matching_route
      assert attrs.route_id == nil
      assert attrs.policy_id == nil
      assert attrs.step_number == nil
      assert attrs.channel_id == nil
    end

    test "the alert snapshot is carried through and defaults to an empty map" do
      snapshot = %{"title" => "Device down", "severity" => "critical"}
      context = base() |> Map.put(:route, nil) |> Map.put(:alert_snapshot, snapshot)

      assert {:ok, attrs} =
               Suppression.to_delivery_attributes(Suppression.evaluate(context), context)

      assert attrs.alert_snapshot == snapshot

      bare = Map.put(base(), :route, nil)

      assert {:ok, %{alert_snapshot: %{}}} =
               Suppression.to_delivery_attributes(Suppression.evaluate(bare), bare)
    end

    test "result_summary is JSON encodable and carries only ids, times, and the reason" do
      context =
        base()
        |> Map.put(:route, %{id: @route_id, throttle_seconds: 300})
        |> Map.put(:last_dispatch_at, DateTime.add(@now, -60, :second))

      outcome = Suppression.evaluate(context)
      assert {:ok, attrs} = Suppression.to_delivery_attributes(outcome, context)

      assert %{"suppression" => summary} = attrs.result_summary
      assert summary["reason"] == "throttled"
      assert summary["evaluated_at"] == DateTime.to_iso8601(@now)
      assert summary["detail"]["effective_seconds"] == 300
      assert summary["detail"]["next_eligible_at"] == DateTime.to_iso8601(attrs_next(outcome))

      assert is_binary(Jason.encode!(attrs.result_summary))
    end

    test "atoms in the detail are stringified rather than persisted as atoms" do
      context = trigger(base(), :schedule)
      outcome = Suppression.evaluate(context)

      assert {:ok, attrs} = Suppression.to_delivery_attributes(outcome, context)
      assert get_in(attrs.result_summary, ["suppression", "detail", "mode"]) == "active_within"
      assert is_binary(Jason.encode!(attrs.result_summary))
    end

    test "every emittable reason round-trips to a JSON encodable summary" do
      for reason <- Suppression.emittable_reasons() do
        context = trigger(base(), reason)
        outcome = Suppression.evaluate(context)

        assert {:suppress, ^reason, _} = outcome
        assert {:ok, attrs} = Suppression.to_delivery_attributes(outcome, context)
        assert attrs.suppression_reason == reason
        assert is_binary(Jason.encode!(attrs.result_summary))
      end
    end
  end

  # --- Fixtures -------------------------------------------------------------

  defp base(overrides \\ %{}) do
    Map.merge(
      %{
        now: @now,
        alert: %{id: @alert_id, status: :pending, device_uid: "dev-1"},
        route: %{id: @route_id},
        policy: %{id: @policy_id},
        step: %{step_number: 1, condition: :if_unacknowledged},
        channel: %{id: @channel_id, enabled: true, execution_route: :control_plane},
        provider: %{id: "provider-1", status: :active}
      },
      overrides
    )
  end

  defp acknowledged_context do
    Map.put(base(), :alert, %{id: @alert_id, status: :acknowledged, acknowledged_at: @past})
  end

  defp silence(overrides \\ %{}) do
    Map.merge(
      %{
        id: "silence-1",
        state: :active,
        starts_at: @past,
        ends_at: @future,
        matchers: %{}
      },
      overrides
    )
  end

  defp schedule(overrides \\ %{}) do
    Map.merge(
      %{
        id: "schedule-1",
        enabled: true,
        timezone: "Etc/UTC",
        mode: :active_within,
        windows: [@business_hours]
      },
      overrides
    )
  end

  defp evening_window do
    %{
      "days" => ["mon", "tue", "wed", "thu", "fri"],
      "start_time" => "18:00",
      "end_time" => "22:00"
    }
  end

  defp attrs_next({:suppress, :throttled, detail}), do: detail.next_eligible_at

  # Each trigger makes exactly one reason true, and only that reason, so the
  # precedence matrix can compose any two of them.
  defp trigger(context, :device_out_of_service) do
    Map.put(context, :device, %{device_uid: "dev-1", is_active: false})
  end

  defp trigger(context, :silence), do: Map.put(context, :silences, [silence()])

  defp trigger(context, :schedule) do
    Map.put(context, :schedule, schedule(%{windows: [%{@business_hours | "days" => ["sun"]}]}))
  end

  defp trigger(context, :snoozed) do
    Map.put(context, :alert, %{
      id: @alert_id,
      status: :pending,
      device_uid: "dev-1",
      snooze_until: @future
    })
  end

  defp trigger(context, :throttled) do
    Map.put(context, :throttle, %{
      throttle_seconds: 300,
      last_dispatch_at: DateTime.add(@now, -60, :second)
    })
  end

  defp trigger(context, :acknowledged) do
    Map.put(context, :alert, %{
      id: @alert_id,
      status: :acknowledged,
      device_uid: "dev-1",
      acknowledged_at: @past
    })
  end

  defp trigger(context, :channel_disabled), do: put_in(context, [:channel, :enabled], false)
  defp trigger(context, :no_matching_route), do: Map.put(context, :route, nil)
end
