defmodule ServiceRadar.Notifications.SuppressionDedupeTest do
  @moduledoc """
  The suppression decision identity, at the row.

  Design D5 requires every withheld notification to be recorded and design C8
  requires an identical repeat to collapse onto the existing row rather than
  growing `notification_deliveries` without bound. Those two pull against each
  other, and the thing that resolves them is the unique index over
  `(alert_id, policy_id, step_number, channel_id, dedupe_key, suppression_reason)`
  plus the `atomic_update` on `occurrence_count`.

  What this suite pins is that the identity is exactly that six-column tuple:
  repeating it collapses, and changing ANY element of it - including
  `suppression_reason`, which an operator reads as a different explanation and
  must therefore be a different row - does not.

  The all-NULL variant of the same tuple (`:no_matching_route`, where
  `policy_id`, `step_number`, and `channel_id` are all NULL) is covered in
  `ServiceRadar.Notifications.DispatcherRoutingTest`, "a repeat of the identical
  decision collapses onto the existing row"; that is the case the index's
  `NULLS NOT DISTINCT` declaration exists for, and it is asserted through the
  dispatcher because that is the path that produces it.
  """

  use ServiceRadar.DataCase, async: true

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Notifications.NotificationChannel
  alias ServiceRadar.Notifications.NotificationDelivery
  alias ServiceRadar.Notifications.NotificationEscalationPolicy
  alias ServiceRadar.Notifications.NotificationProvider
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:notification_suppression_dedupe_test)
    alert = create_alert!(actor)

    {:ok,
     actor: actor,
     alert: alert,
     channel: create_channel!(actor),
     policy: create_policy!(actor),
     baseline: baseline(alert)}
  end

  describe "an identical decision tuple" do
    test "repeated N times leaves exactly one row counting N", context do
      %{actor: actor, alert: alert, baseline: baseline} = context

      attrs = Map.merge(baseline, tuple(context))

      ids = for _repeat <- 1..4, do: suppress!(attrs, actor).id

      assert Enum.uniq(ids) == [List.first(ids)]
      assert [row] = rows_for(alert, actor)
      assert row.occurrence_count == 4
    end

    test "refreshes last_evaluated_at on every repeat", context do
      %{actor: actor, baseline: baseline} = context

      attrs = Map.merge(baseline, tuple(context))

      first = suppress!(attrs, actor)
      second = suppress!(attrs, actor)

      # `occurrence_count` alone answers "how often"; `last_evaluated_at` is what
      # answers "is this still happening?". A collapsed row whose timestamp
      # froze at the first evaluation reads in the Delivery Log as a decision
      # that stopped being made.
      assert DateTime.after?(second.last_evaluated_at, first.last_evaluated_at)
    end

    test "stays suppressed and keeps its reason", context do
      %{actor: actor, alert: alert, baseline: baseline} = context

      attrs = Map.merge(baseline, tuple(context))

      suppress!(attrs, actor)
      suppress!(attrs, actor)

      assert [row] = rows_for(alert, actor)
      assert row.state == :suppressed
      assert row.suppression_reason == :acknowledged
    end
  end

  describe "changing any element of the tuple" do
    setup context do
      %{actor: actor, baseline: baseline} = context

      attrs = Map.merge(baseline, tuple(context))
      suppress!(attrs, actor)

      {:ok, attrs: attrs}
    end

    test "a different suppression_reason is a different row", context do
      %{actor: actor, alert: alert, attrs: attrs} = context

      # The reason IS part of the identity. Two withheld decisions that differ
      # only in why are two different answers to "why was I not paged?", and
      # collapsing them would overwrite the first explanation with the second.
      suppress!(%{attrs | suppression_reason: :silence}, actor)

      assert reasons(alert, actor) == [:acknowledged, :silence]
    end

    test "a different step_number is a different row", context do
      %{actor: actor, alert: alert, attrs: attrs} = context

      suppress!(%{attrs | step_number: 2}, actor)

      assert alert |> rows_for(actor) |> Enum.map(& &1.step_number) |> Enum.sort() == [1, 2]
    end

    test "a different channel_id is a different row", context do
      %{actor: actor, alert: alert, attrs: attrs} = context

      other = create_channel!(actor)
      suppress!(%{attrs | channel_id: other.id}, actor)

      assert alert |> rows_for(actor) |> length() == 2
    end

    test "a different policy_id is a different row", context do
      %{actor: actor, alert: alert, attrs: attrs} = context

      other = create_policy!(actor)
      suppress!(%{attrs | policy_id: other.id}, actor)

      assert alert |> rows_for(actor) |> length() == 2
    end

    test "a different dedupe_key is a different row", context do
      %{actor: actor, alert: alert, attrs: attrs} = context

      # A new dedupe key is a new incident window, so the count restarts rather
      # than accumulating across incidents that only look alike.
      suppress!(%{attrs | dedupe_key: "second-window"}, actor)

      assert alert |> rows_for(actor) |> Enum.map(& &1.occurrence_count) == [1, 1]
    end

    test "a different alert is a different row", context do
      %{actor: actor, alert: alert, attrs: attrs} = context

      other = create_alert!(actor)

      suppress!(%{attrs | alert_id: other.id, alert_snapshot: snapshot(other)}, actor)

      assert alert |> rows_for(actor) |> length() == 1
      assert other |> rows_for(actor) |> length() == 1
    end
  end

  describe "retaining decisions after parent deletion" do
    test "deleting alerts cannot collide decisions that differed by alert id", context do
      %{actor: actor, alert: alert, baseline: baseline} = context
      other = create_alert!(actor)
      attrs = Map.merge(baseline, tuple(context))

      first = suppress!(attrs, actor)

      second =
        suppress!(%{attrs | alert_id: other.id, alert_snapshot: snapshot(other)}, actor)

      for parent <- [alert, other] do
        {:ok, parent_id} = Ecto.UUID.dump(parent.id)

        assert {:ok, %{num_rows: 1}} =
                 SQL.query(
                   Repo,
                   "DELETE FROM platform.alerts WHERE id = $1",
                   [parent_id]
                 )
      end

      {:ok, %{rows: retained}} =
        SQL.query(
          Repo,
          """
          SELECT alert_id, suppression_alert_id::text
            FROM platform.notification_deliveries
           WHERE id::text = ANY($1::text[])
           ORDER BY suppression_alert_id::text
          """,
          [[first.id, second.id]]
        )

      assert retained == Enum.sort([[nil, alert.id], [nil, other.id]])
    end
  end

  # --- fixtures -------------------------------------------------------------

  defp baseline(alert) do
    %{
      alert_id: alert.id,
      alert_snapshot: snapshot(alert),
      dedupe_key: "first-window",
      suppression_reason: :acknowledged
    }
  end

  defp tuple(%{policy: policy, channel: channel}) do
    %{policy_id: policy.id, step_number: 1, channel_id: channel.id}
  end

  defp snapshot(alert), do: %{"id" => alert.id, "title" => alert.title, "severity" => "critical"}

  defp suppress!(attrs, actor) do
    NotificationDelivery
    |> Ash.Changeset.for_create(:record_suppression, attrs, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp rows_for(alert, actor) do
    NotificationDelivery
    |> Ash.Query.filter(alert_id == ^alert.id)
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.read!(actor: actor)
  end

  defp reasons(alert, actor) do
    alert |> rows_for(actor) |> Enum.map(& &1.suppression_reason) |> Enum.sort()
  end

  defp create_alert!(actor) do
    Alert
    |> Ash.Changeset.for_create(
      :trigger,
      %{
        title: "Device unreachable #{System.unique_integer([:positive])}",
        description: "ICMP failed three times",
        severity: :critical,
        source_type: :device
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_channel!(actor) do
    provider =
      NotificationProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_key: "webhook-#{System.unique_integer([:positive])}",
          provider_type: :native,
          display_name: "Test webhook",
          capabilities: [:send, :test],
          supported_routes: [:control_plane],
          payload_formats: [:json],
          config_schema: %{},
          implementation_module: "ServiceRadar.Notifications.Transports.GenericWebhook"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    NotificationChannel
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "channel-#{System.unique_integer([:positive])}",
        provider_id: provider.id,
        config: %{}
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_policy!(actor) do
    NotificationEscalationPolicy
    |> Ash.Changeset.for_create(
      :create,
      %{name: "policy-#{System.unique_integer([:positive])}"},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
