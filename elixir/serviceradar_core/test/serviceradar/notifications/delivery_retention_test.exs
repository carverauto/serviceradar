defmodule ServiceRadar.Notifications.DeliveryRetentionTest do
  @moduledoc """
  The delivery pruner against a real `notification_deliveries` table.

  The unit suite pins the window, the predicate text, and the batching with an
  injected query function, which is where the logic lives. What it cannot prove
  is that the statement is valid against the schema that actually shipped: a
  renamed column, a missing `last_evaluated_at`, or a `state` comparison that
  does not match the enum's storage all produce a statement that looks right in a
  string assertion and fails the first time it runs at 04:11.

  So this suite runs the real delete once, and pins the one behaviour a mistake
  here would silently invert: an owed delivery is never pruned. Deleting a
  `:pending` row cancels a page nobody asked to cancel, and unlike a missed prune
  it leaves no evidence.
  """

  use ServiceRadar.DataCase, async: true

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Notifications.DeliveryRetentionWorker
  alias ServiceRadar.Notifications.NotificationDelivery
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  @now ~U[2026-08-09 12:00:00.000000Z]

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:notification_retention_test)}
  end

  describe "prune/2" do
    test "removes a settled delivery past the window", %{actor: actor} do
      sent = create_delivery!(actor)
      {:ok, sent} = mark_sent(sent, actor)
      backdate!(sent.id, 400)

      assert :ok = DeliveryRetentionWorker.prune(job(), now: @now)

      refute exists?(sent.id, actor)
    end

    test "keeps an owed delivery no matter how old it is", %{actor: actor} do
      # :pending is where a retry-eligible delivery waits (design D4 - retry does
      # not pass through :failed). Deleting it silently cancels the page.
      pending = create_delivery!(actor)
      backdate!(pending.id, 400)

      assert :ok = DeliveryRetentionWorker.prune(job(), now: @now)

      assert exists?(pending.id, actor)
    end

    test "keeps a settled delivery inside the window", %{actor: actor} do
      recent = create_delivery!(actor)
      {:ok, recent} = mark_sent(recent, actor)

      assert :ok = DeliveryRetentionWorker.prune(job(), now: @now)

      assert exists?(recent.id, actor)
    end
  end

  defp job, do: %Oban.Job{args: %{}}

  defp create_delivery!(actor) do
    NotificationDelivery
    |> Ash.Changeset.for_create(
      :record_dispatch,
      %{
        alert_snapshot: %{"id" => Ash.UUID.generate(), "title" => "retention fixture"},
        dedupe_key: "retention-" <> Ash.UUID.generate(),
        max_attempts: 3,
        queued_at: @now,
        next_attempt_at: @now
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp mark_sent(delivery, actor) do
    delivery
    |> Ash.Changeset.for_update(:record_sent, %{}, actor: actor)
    |> Ash.update(actor: actor)
  end

  # `inserted_at` is a create timestamp, so aging a row is a database edit
  # rather than an attribute the resource accepts.
  defp backdate!(id, days) do
    cutoff = DateTime.add(@now, -days * 86_400, :second)

    SQL.query!(
      Repo,
      "UPDATE platform.notification_deliveries SET inserted_at = $1 WHERE id = $2",
      [cutoff, Ecto.UUID.dump!(id)]
    )
  end

  defp exists?(id, actor) do
    NotificationDelivery
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, nil} -> false
      {:ok, _delivery} -> true
    end
  end
end
