defmodule ServiceRadar.Notifications.ActionRedemptionTest do
  @moduledoc """
  The action-link path against real rows.

  The pure suites pin the credential scheme and the link shape. What they cannot
  prove is the part that only a database can enforce: that the digest is what
  lands in `notification_action_tokens` and the plaintext is nowhere, and that
  single use is a compare-and-set rather than a read-then-write that two
  concurrent clicks can both pass.

  So this suite is deliberately small and covers exactly those, plus the
  end-to-end redemption through the existing `Alert` actions.
  """

  use ServiceRadar.DataCase, async: true

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Notifications.ActionLinks
  alias ServiceRadar.Notifications.ActionRedemption
  alias ServiceRadar.Notifications.ActionToken
  alias ServiceRadar.Notifications.NotificationAcknowledgement
  alias ServiceRadar.Notifications.NotificationActionToken
  alias ServiceRadar.Notifications.NotificationDelivery
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  @base "https://serviceradar.example.com"
  @now ~U[2026-08-09 12:00:00.000000Z]

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:notification_action_link_test)
    alert = create_alert!(actor)
    delivery = create_delivery!(alert, actor)

    {:ok, actor: actor, alert: alert, delivery: delivery}
  end

  describe "only the digest is persisted" do
    test "the plaintext token is in no column of the row it created", %{
      actor: actor,
      delivery: delivery
    } do
      links = issue!(delivery, actor)
      minted = Enum.find(links.minted, &(&1.action == :acknowledge))

      row = fetch_row!(minted.selector)

      # Every value in the row, dumped straight from Postgres, so a column added
      # later without thought still fails this.
      for value <- Map.values(row), is_binary(value) do
        refute value =~ minted.token
        refute value =~ secret_of(minted.token)
      end

      assert row["token_hash"] =~ ~r/\A[0-9a-f]{64}\z/
      assert row["selector"] == minted.selector
    end

    test "the whole table contains no plaintext anywhere", %{actor: actor, delivery: delivery} do
      links = issue!(delivery, actor)
      minted = Enum.find(links.minted, &(&1.action == :resolve))

      %{rows: [[count]]} =
        SQL.query!(
          Repo,
          """
          SELECT count(*) FROM platform.notification_action_tokens
          WHERE selector LIKE $1 OR token_hash LIKE $1
          """,
          ["%" <> secret_of(minted.token) <> "%"]
        )

      assert count == 0
    end
  end

  describe "verify/2 against a real row" do
    test "a minted capability round trips through the database", %{
      actor: actor,
      delivery: delivery,
      alert: alert
    } do
      links = issue!(delivery, actor)
      minted = Enum.find(links.minted, &(&1.action == :acknowledge))

      assert {:ok, :active, record} =
               ActionToken.verify(minted.token, actor: actor, now: @now)

      assert record.alert_id == alert.id
      assert record.delivery_id == delivery.id
      assert record.action == :acknowledge
    end

    test "an unknown selector is refused with the same answer a bad secret gets", %{actor: actor} do
      {:ok, decoy} =
        ActionToken.mint(
          %{
            delivery_id: Ash.UUID.generate(),
            alert_id: Ash.UUID.generate(),
            action: :acknowledge
          },
          now: @now
        )

      assert {:error, :invalid_token} = ActionToken.verify(decoy.token, actor: actor, now: @now)
    end

    test "a token minted for one alert cannot verify against another alert's expectation", %{
      actor: actor,
      delivery: delivery
    } do
      links = issue!(delivery, actor)
      minted = Enum.find(links.minted, &(&1.action == :acknowledge))

      other_alert = create_alert!(actor, "second incident")

      assert {:error, :alert_mismatch} =
               ActionToken.verify(minted.token,
                 actor: actor,
                 now: @now,
                 expect_alert_id: other_alert.id
               )
    end
  end

  describe "single use is a compare-and-set" do
    test "the second consume of one token loses rather than applying twice", %{
      actor: actor,
      delivery: delivery
    } do
      links = issue!(delivery, actor)
      minted = Enum.find(links.minted, &(&1.action == :acknowledge))

      {:ok, :active, record} = ActionToken.verify(minted.token, actor: actor, now: @now)

      assert {:ok, consumed} = ActionToken.consume(record, actor: actor)
      assert consumed.consumed_at

      # The stale in-memory copy is exactly what a second request holds.
      assert {:error, :already_consumed} = ActionToken.consume(record, actor: actor)
    end
  end

  describe "redeem/2" do
    test "acknowledging moves the alert and writes one audit row", %{
      actor: actor,
      alert: alert,
      delivery: delivery
    } do
      links = issue!(delivery, actor)
      minted = Enum.find(links.minted, &(&1.action == :acknowledge))

      assert {:ok, outcome} = ActionRedemption.redeem(minted.token, actor: actor, now: @now)

      assert outcome.status == :applied
      assert outcome.action == :acknowledge
      assert outcome.alert_id == alert.id

      assert {:ok, reloaded} = Alert.get_by_id(alert.id, actor: actor)
      assert reloaded.status == :acknowledged
      assert reloaded.acknowledged_by == "action_link:" <> delivery.id

      assert [acknowledgement] = acknowledgements(alert.id, actor)
      assert acknowledgement.action == :acknowledge
      assert acknowledgement.actor_kind == :external_principal
      assert acknowledgement.source == :action_link
      assert acknowledgement.external_principal == "action_link:" <> delivery.id
      assert acknowledgement.actor_user_id == nil
      assert acknowledgement.delivery_id == delivery.id
    end

    test "presenting the same link twice changes nothing the second time", %{
      actor: actor,
      alert: alert,
      delivery: delivery
    } do
      links = issue!(delivery, actor)
      minted = Enum.find(links.minted, &(&1.action == :acknowledge))

      assert {:ok, %{status: :applied}} =
               ActionRedemption.redeem(minted.token, actor: actor, now: @now)

      assert {:ok, replay} = ActionRedemption.redeem(minted.token, actor: actor, now: @now)

      # Idempotent success, not an error: a mail scanner that GETs every link and
      # a human who double-clicks produce the same request.
      assert replay.status == :replayed
      assert replay.consumed_at

      # And nothing was written a second time.
      assert length(acknowledgements(alert.id, actor)) == 1
    end

    test "a second, different link for an already-acknowledged alert is audited, not applied", %{
      actor: actor,
      alert: alert,
      delivery: delivery
    } do
      # The fan-out case: acknowledged in Slack, then the email link is clicked.
      first = issue!(delivery, actor)
      second = issue!(delivery, actor)

      assert {:ok, %{status: :applied}} =
               ActionRedemption.redeem(token_for(first, :acknowledge), actor: actor, now: @now)

      assert {:ok, outcome} =
               ActionRedemption.redeem(token_for(second, :acknowledge), actor: actor, now: @now)

      assert outcome.status == :already_applied

      # A second human acting IS an event, so it is audited even though the alert
      # did not transition twice.
      assert length(acknowledgements(alert.id, actor)) == 2

      assert {:ok, reloaded} = Alert.get_by_id(alert.id, actor: actor)
      assert reloaded.status == :acknowledged
    end

    test "snoozing records snooze_until on the alert and on the audit row", %{
      actor: actor,
      alert: alert,
      delivery: delivery
    } do
      # `Alert.snooze` validates `snooze_until` against the wall clock, so this
      # is one of the few places the real clock has to be the input. Issue the
      # token at that same instant; a frozen `@now` older than the 3-day TTL
      # makes redeem return `:token_expired`.
      now = DateTime.utc_now()
      links = issue!(delivery, actor, now: now)

      assert {:ok, outcome} =
               ActionRedemption.redeem(token_for(links, :snooze), actor: actor, now: now)

      expected = DateTime.add(now, 3600, :second)

      assert outcome.status == :applied
      assert DateTime.compare(outcome.snooze_until, expected) == :eq

      assert {:ok, reloaded} = Alert.get_by_id(alert.id, actor: actor)
      assert DateTime.compare(reloaded.snooze_until, expected) == :eq
      # Snooze is deliberately not a state-machine state.
      assert reloaded.status == :pending

      assert [acknowledgement] = acknowledgements(alert.id, actor)
      assert acknowledgement.action == :snooze
      assert DateTime.compare(acknowledgement.snooze_until, expected) == :eq
    end

    test "the snooze duration comes from the token, not from the request", %{
      actor: actor,
      alert: alert,
      delivery: delivery
    } do
      now = DateTime.utc_now()
      links = issue!(delivery, actor, now: now, snooze_seconds: 600)

      assert {:ok, _outcome} =
               ActionRedemption.redeem(token_for(links, :snooze),
                 actor: actor,
                 now: now,
                 snooze_seconds: 999_999
               )

      assert {:ok, reloaded} = Alert.get_by_id(alert.id, actor: actor)
      assert DateTime.compare(reloaded.snooze_until, DateTime.add(now, 600, :second)) == :eq
    end

    test "resolving moves the alert", %{actor: actor, alert: alert, delivery: delivery} do
      links = issue!(delivery, actor)
      token = token_for(links, :resolve)
      test_pid = self()
      alert_id = alert.id

      enqueue = fn alert_id, reason ->
        send(test_pid, {:routing_enqueued, alert_id, reason})
        {:ok, :job}
      end

      assert {:ok, %{status: :applied}} =
               ActionRedemption.redeem(token,
                 actor: actor,
                 now: @now,
                 enqueue_routing: enqueue
               )

      assert {:ok, reloaded} = Alert.get_by_id(alert.id, actor: actor)
      assert reloaded.status == :resolved
      assert reloaded.resolved_by == "action_link:" <> delivery.id
      assert_received {:routing_enqueued, ^alert_id, :resolve}

      assert {:ok, %{status: :replayed}} =
               ActionRedemption.redeem(token,
                 actor: actor,
                 now: @now,
                 enqueue_routing: enqueue
               )

      refute_received {:routing_enqueued, _, _}
    end

    test "an enqueue failure leaves a signed resolve link unspent", %{
      actor: actor,
      alert: alert,
      delivery: delivery
    } do
      links = issue!(delivery, actor)
      minted = Enum.find(links.minted, &(&1.action == :resolve))

      assert {:error, {:routing_enqueue_failed, :queue_down}} =
               ActionRedemption.redeem(minted.token,
                 actor: actor,
                 now: @now,
                 enqueue_routing: fn _alert_id, _reason -> {:error, :queue_down} end
               )

      assert {:ok, reloaded} = Alert.get_by_id(alert.id, actor: actor)
      assert reloaded.status == :pending
      assert acknowledgements(alert.id, actor) == []
      assert fetch_row!(minted.selector)["consumed_at"] == nil
    end

    test "an escalated alert can still be acknowledged", %{
      actor: actor,
      alert: alert,
      delivery: delivery
    } do
      # The alerts that escalated are exactly the ones a human most needs to take
      # ownership of, and `Suppression.acknowledged?/1` keys strictly on
      # `status == :acknowledged`, so a ladder that cannot be answered never
      # stops.
      {:ok, escalated} =
        alert
        |> Ash.Changeset.for_update(:escalate, %{reason: "no response"}, actor: actor)
        |> Ash.update(actor: actor)

      assert escalated.status == :escalated

      links = issue!(delivery, actor)

      assert {:ok, %{status: :applied}} =
               ActionRedemption.redeem(token_for(links, :acknowledge), actor: actor, now: @now)

      assert {:ok, reloaded} = Alert.get_by_id(alert.id, actor: actor)
      assert reloaded.status == :acknowledged
    end

    test "a resolved alert refuses an acknowledge link rather than crashing", %{
      actor: actor,
      alert: alert,
      delivery: delivery
    } do
      links = issue!(delivery, actor)

      {:ok, _resolved} =
        alert
        |> Ash.Changeset.for_update(:resolve, %{resolved_by: "someone"}, actor: actor)
        |> Ash.update(actor: actor)

      assert {:error, {:alert_not_actionable, :resolved}} =
               ActionRedemption.redeem(token_for(links, :acknowledge), actor: actor, now: @now)
    end

    test "an expired link applies nothing", %{actor: actor, alert: alert, delivery: delivery} do
      links = issue!(delivery, actor, ttl_seconds: 60)
      later = DateTime.add(@now, 3600, :second)

      assert {:error, :token_expired} =
               ActionRedemption.redeem(token_for(links, :acknowledge), actor: actor, now: later)

      assert {:ok, reloaded} = Alert.get_by_id(alert.id, actor: actor)
      assert reloaded.status == :pending
      assert acknowledgements(alert.id, actor) == []
    end

    test "a failed application leaves the capability unspent", %{
      actor: actor,
      alert: alert,
      delivery: delivery
    } do
      # The consume, the transition, and the audit row commit together. Without
      # that, an operator would hold a dead link and an unacknowledged alert.
      links = issue!(delivery, actor)
      minted = Enum.find(links.minted, &(&1.action == :acknowledge))

      {:ok, _resolved} =
        alert
        |> Ash.Changeset.for_update(:resolve, %{resolved_by: "someone"}, actor: actor)
        |> Ash.update(actor: actor)

      assert {:error, {:alert_not_actionable, :resolved}} =
               ActionRedemption.redeem(minted.token, actor: actor, now: @now)

      assert fetch_row!(minted.selector)["consumed_at"] == nil
    end
  end

  describe "the :stream provider never reaches this table" do
    test "issuing links for a broadcast writes no capability", %{
      actor: actor,
      delivery: delivery
    } do
      assert {:ok, links} =
               ActionLinks.issue(delivery, %{provider_type: :stream},
                 actor: actor,
                 base_url: @base,
                 now: @now
               )

      assert links.minted == []
      assert token_count(delivery.id) == 0
    end

    test "issuing links for a native channel writes exactly three", %{
      actor: actor,
      delivery: delivery
    } do
      assert {:ok, _links} =
               ActionLinks.issue(delivery, %{provider_type: :native},
                 actor: actor,
                 base_url: @base,
                 now: @now
               )

      assert token_count(delivery.id) == 3
    end
  end

  describe "apply_native/2 - the interactive-component ingress (task 4.3.7)" do
    test "acknowledges the alert on the same code path an action link uses", %{
      actor: actor,
      alert: alert,
      delivery: delivery
    } do
      assert {:ok, outcome} =
               ActionRedemption.apply_native(
                 %{action: :acknowledge, alert_id: alert.id, delivery_id: delivery.id},
                 actor: actor,
                 external_principal: "slack:U123",
                 now: @now
               )

      assert outcome.status == :applied
      assert outcome.action == :acknowledge

      # The acknowledged state is what halts escalation, and it is reached
      # through the same Alert action a redeemed link uses. A native ingress that
      # left the alert pending would keep paging.
      assert {:ok, reloaded} = Alert.get_by_id(alert.id, actor: actor)
      assert reloaded.status == :acknowledged
      assert reloaded.acknowledged_by == "slack:U123"
    end

    test "records the acknowledgement as a callback by an external principal", %{
      actor: actor,
      alert: alert,
      delivery: delivery
    } do
      assert {:ok, _outcome} =
               ActionRedemption.apply_native(
                 %{action: :acknowledge, alert_id: alert.id, delivery_id: delivery.id},
                 actor: actor,
                 external_principal: "slack:U123",
                 now: @now
               )

      assert [row] = acknowledgements(alert.id, actor)
      assert row.source == :callback
      assert row.actor_kind == :external_principal
      assert row.external_principal == "slack:U123"
      assert row.delivery_id == delivery.id
    end

    test "absorbs a provider retry without transitioning the alert twice", %{
      actor: actor,
      alert: alert,
      delivery: delivery
    } do
      capability = %{action: :acknowledge, alert_id: alert.id, delivery_id: delivery.id}
      opts = [actor: actor, external_principal: "slack:U123", now: @now]

      assert {:ok, first} = ActionRedemption.apply_native(capability, opts)
      assert {:ok, second} = ActionRedemption.apply_native(capability, opts)

      assert first.status == :applied
      # Slack retries a delivery it did not see acked. There is no single-use
      # token here to absorb it, so the guard is the disposition check against
      # the alert's current state - the same one that absorbs a double-clicked
      # action link.
      assert second.status == :already_applied

      assert {:ok, reloaded} = Alert.get_by_id(alert.id, actor: actor)
      assert reloaded.status == :acknowledged

      # Both receipts are still audited: the second is evidence that a person
      # clicked again, which is worth keeping even though it changed nothing.
      assert length(acknowledgements(alert.id, actor)) == 2
    end

    test "resolves through the same path", %{actor: actor, alert: alert, delivery: delivery} do
      test_pid = self()
      alert_id = alert.id

      assert {:ok, outcome} =
               ActionRedemption.apply_native(
                 %{action: :resolve, alert_id: alert.id, delivery_id: delivery.id},
                 actor: actor,
                 external_principal: "pagerduty:PABC",
                 now: @now,
                 enqueue_routing: fn alert_id, reason ->
                   send(test_pid, {:routing_enqueued, alert_id, reason})
                   {:ok, :job}
                 end
               )

      assert outcome.status == :applied
      assert {:ok, reloaded} = Alert.get_by_id(alert.id, actor: actor)
      assert reloaded.status in [:resolved, :closed]
      assert_received {:routing_enqueued, ^alert_id, :resolve}
    end

    test "a provider retry does not enqueue a second close-out", %{
      actor: actor,
      alert: alert,
      delivery: delivery
    } do
      test_pid = self()
      alert_id = alert.id
      capability = %{action: :resolve, alert_id: alert.id, delivery_id: delivery.id}

      opts = [
        actor: actor,
        external_principal: "pagerduty:PABC",
        now: @now,
        enqueue_routing: fn alert_id, reason ->
          send(test_pid, {:routing_enqueued, alert_id, reason})
          {:ok, :job}
        end
      ]

      assert {:ok, %{status: :applied}} = ActionRedemption.apply_native(capability, opts)
      assert {:ok, %{status: :already_applied}} = ActionRedemption.apply_native(capability, opts)
      assert_received {:routing_enqueued, ^alert_id, :resolve}
      refute_received {:routing_enqueued, _, _}
    end

    test "an enqueue failure rolls back a native resolution", %{
      actor: actor,
      alert: alert,
      delivery: delivery
    } do
      assert {:error, {:routing_enqueue_failed, :queue_down}} =
               ActionRedemption.apply_native(
                 %{action: :resolve, alert_id: alert.id, delivery_id: delivery.id},
                 actor: actor,
                 external_principal: "pagerduty:PABC",
                 now: @now,
                 enqueue_routing: fn _alert_id, _reason -> {:error, :queue_down} end
               )

      assert {:ok, reloaded} = Alert.get_by_id(alert.id, actor: actor)
      assert reloaded.status == :pending
      assert acknowledgements(alert.id, actor) == []
    end

    test "refuses a snooze that carries no duration", %{
      actor: actor,
      alert: alert,
      delivery: delivery
    } do
      # `ActionToken` requires an explicit duration, so this ingress does too.
      # A house default here would mean the two ingresses to one mechanism
      # disagreed about how long "snooze" is.
      assert {:error, :missing_snooze_seconds} =
               ActionRedemption.apply_native(
                 %{action: :snooze, alert_id: alert.id, delivery_id: delivery.id},
                 actor: actor,
                 now: @now
               )

      assert {:ok, reloaded} = Alert.get_by_id(alert.id, actor: actor)
      assert reloaded.status == :pending
    end

    test "snoozes when given a duration", %{actor: actor, alert: alert, delivery: delivery} do
      # Real time rather than the suite's fixed @now: the Alert `:snooze` action
      # validates that `snooze_until` is in the future against the wall clock, so
      # a duration measured from a pinned past instant is rejected on its merits.
      now = DateTime.utc_now()

      assert {:ok, outcome} =
               ActionRedemption.apply_native(
                 %{
                   action: :snooze,
                   alert_id: alert.id,
                   delivery_id: delivery.id,
                   snooze_seconds: 900
                 },
                 actor: actor,
                 external_principal: "discord:1234",
                 now: now
               )

      assert outcome.status == :applied
      assert DateTime.compare(outcome.snooze_until, DateTime.add(now, 900, :second)) == :eq

      assert {:ok, reloaded} = Alert.get_by_id(alert.id, actor: actor)
      assert reloaded.status == :pending
      assert reloaded.snooze_until
    end

    test "refuses a capability that names no alert or an unknown action", %{actor: actor} do
      assert {:error, :invalid_native_capability} =
               ActionRedemption.apply_native(%{action: :acknowledge}, actor: actor)

      assert {:error, :invalid_native_capability} =
               ActionRedemption.apply_native(
                 %{action: :delete_everything, alert_id: Ash.UUID.generate()},
                 actor: actor
               )
    end
  end

  # --- fixtures -------------------------------------------------------------

  defp issue!(delivery, actor, opts \\ []) do
    opts = Keyword.merge([actor: actor, base_url: @base, now: @now], opts)

    assert {:ok, links} = ActionLinks.issue(delivery, %{provider_type: :native}, opts)
    links
  end

  defp token_for(links, action) do
    Enum.find(links.minted, &(&1.action == action)).token
  end

  defp secret_of(token) do
    [_version, _selector, secret] = String.split(token, ".")
    secret
  end

  defp create_alert!(actor, title \\ "Device tonka01 is unreachable") do
    Alert
    |> Ash.Changeset.for_create(
      :trigger,
      %{
        title: title,
        description: "ICMP probe failed three consecutive times",
        severity: :critical,
        source_type: :service_check,
        source_id: "action-link-fixture"
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_delivery!(alert, actor) do
    NotificationDelivery
    |> Ash.Changeset.for_create(
      :record_dispatch,
      %{
        alert_id: alert.id,
        alert_snapshot: %{"id" => alert.id, "title" => alert.title},
        dedupe_key: "action-link-" <> Ash.UUID.generate(),
        max_attempts: 3,
        queued_at: @now,
        next_attempt_at: @now
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp acknowledgements(alert_id, actor) do
    {:ok, rows} = NotificationAcknowledgement.list_for_alert(alert_id, actor: actor)
    rows
  end

  defp token_count(delivery_id) do
    {:ok, rows} = NotificationActionToken.list_for_delivery(delivery_id, actor: system())
    length(rows)
  end

  defp system, do: SystemActor.system(:notification_action_link_test)

  defp fetch_row!(selector) do
    %{columns: columns, rows: [row]} =
      SQL.query!(
        Repo,
        "SELECT * FROM platform.notification_action_tokens WHERE selector = $1",
        [selector]
      )

    columns |> Enum.zip(row) |> Map.new()
  end
end
