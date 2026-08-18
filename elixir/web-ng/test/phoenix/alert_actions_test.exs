defmodule ServiceRadarWebNG.AlertActionsTest do
  @moduledoc """
  Decision-core tests for the alert acknowledgement surface.

  Everything here is database free: duration parsing, the derived "snoozed"
  condition, which controls the state machine permits, and the delivery
  counting rule that keeps test sends out of operator-facing totals.
  """

  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.AlertActions

  @moduletag :db_free

  describe "snooze_seconds/1" do
    test "maps every enumerated option to its seconds" do
      for %{value: value, seconds: seconds} <- AlertActions.snooze_options() do
        assert {:ok, ^seconds} = AlertActions.snooze_seconds(%{"duration" => value})
      end
    end

    test "accepts a bounded custom duration in minutes" do
      assert {:ok, 5_400} =
               AlertActions.snooze_seconds(%{"duration" => "custom", "custom_minutes" => "90"})

      assert {:ok, seconds} =
               AlertActions.snooze_seconds(%{
                 "duration" => "custom",
                 "custom_minutes" => to_string(AlertActions.min_custom_snooze_minutes())
               })

      assert seconds == AlertActions.min_custom_snooze_minutes() * 60
    end

    test "refuses a custom duration outside the bound" do
      too_small = AlertActions.min_custom_snooze_minutes() - 1
      too_large = AlertActions.max_custom_snooze_minutes() + 1

      assert :error =
               AlertActions.snooze_seconds(%{
                 "duration" => "custom",
                 "custom_minutes" => to_string(too_small)
               })

      assert :error =
               AlertActions.snooze_seconds(%{
                 "duration" => "custom",
                 "custom_minutes" => to_string(too_large)
               })
    end

    test "refuses anything outside the whitelist without creating an atom" do
      crafted = "definitely_not_a_snooze_duration_atom"

      assert :error = AlertActions.snooze_seconds(%{"duration" => crafted})
      assert :error = AlertActions.snooze_seconds(%{"duration" => "1h "})
      assert :error = AlertActions.snooze_seconds(%{})
      assert :error = AlertActions.snooze_seconds(nil)

      assert_raise ArgumentError, fn -> String.to_existing_atom(crafted) end
    end

    test "refuses a non-integer custom duration" do
      assert :error =
               AlertActions.snooze_seconds(%{"duration" => "custom", "custom_minutes" => "90abc"})

      assert :error =
               AlertActions.snooze_seconds(%{"duration" => "custom", "custom_minutes" => ""})

      assert :error = AlertActions.snooze_seconds(%{"duration" => "custom"})
    end
  end

  describe "snoozed?/2" do
    setup do
      %{now: ~U[2026-08-09 12:00:00.000000Z]}
    end

    test "is derived from status plus a future snooze_until", %{now: now} do
      future = DateTime.add(now, 600, :second)

      assert AlertActions.snoozed?(%{status: :pending, snooze_until: future}, now)
      assert AlertActions.snoozed?(%{status: :escalated, snooze_until: future}, now)
    end

    test "an elapsed snooze is not snoozed", %{now: now} do
      past = DateTime.add(now, -1, :second)

      refute AlertActions.snoozed?(%{status: :pending, snooze_until: past}, now)
    end

    test "only pending and escalated can be snoozed", %{now: now} do
      future = DateTime.add(now, 600, :second)

      for status <- [:acknowledged, :resolved, :suppressed] do
        refute AlertActions.snoozed?(%{status: status, snooze_until: future}, now)
      end
    end

    test "no snooze_until is not snoozed", %{now: now} do
      refute AlertActions.snoozed?(%{status: :pending, snooze_until: nil}, now)
      refute AlertActions.snoozed?(nil, now)
    end
  end

  describe "action_states/2" do
    test "acknowledge accepts pending AND escalated" do
      assert %{acknowledge: %{enabled?: true}} = AlertActions.action_states(%{status: :pending})
      assert %{acknowledge: %{enabled?: true}} = AlertActions.action_states(%{status: :escalated})
    end

    test "a resolved alert disables acknowledge and snooze with an explanation" do
      states = AlertActions.action_states(%{status: :resolved})

      assert %{enabled?: false, reason: ack_reason} = states.acknowledge
      assert %{enabled?: false, reason: snooze_reason} = states.snooze
      assert %{enabled?: false} = states.resolve

      assert is_binary(ack_reason) and ack_reason != ""
      assert is_binary(snooze_reason) and snooze_reason != ""
    end

    test "an acknowledged alert can still be resolved but not re-acknowledged" do
      states = AlertActions.action_states(%{status: :acknowledged})

      assert %{enabled?: false} = states.acknowledge
      assert %{enabled?: true} = states.resolve
    end

    test "a suppressed alert cannot be resolved without being reopened" do
      states = AlertActions.action_states(%{status: :suppressed})

      assert %{enabled?: false, reason: reason} = states.resolve
      assert reason =~ "reopen"
    end

    test "unsnooze is offered only while the alert is actually snoozed" do
      now = ~U[2026-08-09 12:00:00.000000Z]
      future = DateTime.add(now, 600, :second)

      snoozed = AlertActions.action_states(%{status: :pending, snooze_until: future}, now)
      plain = AlertActions.action_states(%{status: :pending, snooze_until: nil}, now)

      assert %{enabled?: true} = snoozed.unsnooze
      assert %{enabled?: false} = plain.unsnooze
    end

    test "a missing alert disables everything" do
      states = AlertActions.action_states(nil)

      for key <- [:acknowledge, :snooze, :unsnooze, :resolve] do
        assert %{enabled?: false, reason: reason} = Map.fetch!(states, key)
        assert is_binary(reason)
      end
    end
  end

  describe "delivery_counts/1" do
    test "test sends are excluded from every count and reported separately" do
      deliveries = [
        %{state: :sent, is_test: false},
        %{state: :suppressed, is_test: false},
        %{state: :pending, is_test: false},
        %{state: :failed, is_test: false},
        %{state: :sent, is_test: true},
        %{state: :sent, is_test: true},
        %{state: :sent, is_test: true}
      ]

      counts = AlertActions.delivery_counts(deliveries)

      # Three test sends plus one real delivery on the same channel reports one
      # notification, not four.
      assert counts.total == 4
      assert counts.sent == 1
      assert counts.suppressed == 1
      assert counts.pending == 1
      assert counts.failed == 1
      assert counts.test == 3
    end

    test "an empty history counts zero" do
      counts = AlertActions.delivery_counts([])

      assert counts.total == 0
      assert counts.test == 0
    end
  end

  describe "labels" do
    test "every recorded suppression reason has an explanation" do
      reasons = [
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

      for reason <- reasons do
        label = AlertActions.suppression_reason_label(reason)
        assert is_binary(label) and label != ""
      end

      assert is_nil(AlertActions.suppression_reason_label(nil))
    end

    test "state labels carry text, so state is never conveyed by colour alone" do
      for state <- [:pending, :dispatching, :sent, :failed, :expired, :cancelled, :suppressed, :skipped] do
        assert is_binary(AlertActions.delivery_state_label(state))
        assert is_binary(AlertActions.delivery_state_variant(state))
      end
    end
  end

  describe "delivery_log_path/1" do
    test "filters the delivery log to one alert" do
      path = AlertActions.delivery_log_path("11111111-2222-3333-4444-555555555555")

      assert path =~ "/settings/notifications/deliveries"
      assert path =~ "alert_id=11111111-2222-3333-4444-555555555555"
    end
  end

  describe "bulk/4 input guards" do
    test "an empty selection is refused before any authorization work" do
      assert {:error, :empty_selection} = AlertActions.bulk(nil, :acknowledge, [], [])
    end

    test "a selection larger than the limit is refused whole" do
      ids = Enum.map(1..(AlertActions.bulk_limit() + 1), &"id-#{&1}")

      assert {:error, {:selection_too_large, limit}} = AlertActions.bulk(nil, :acknowledge, ids, [])
      assert limit == AlertActions.bulk_limit()
    end

    test "an unsupported action is refused" do
      assert {:error, :not_authorized} = AlertActions.bulk(nil, :destroy, ["id"], [])
    end
  end

  describe "describe_error/1" do
    test "never discloses whether a rejected id exists" do
      message = AlertActions.describe_error(:not_in_current_results)

      assert is_binary(message)
      refute message =~ "exist"
      refute message =~ "found"
    end

    test "renders the state machine refusal verbatim" do
      assert "Already resolved" == AlertActions.describe_error({:not_allowed, "Already resolved"})
    end
  end
end
