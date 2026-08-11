defmodule ServiceRadar.Notifications.RateLimiterDurabilityTest do
  @moduledoc """
  The property that made this module exist: the budget survives a restart.

  `ServiceRadar.Monitoring.WebhookNotifier` held its rate-limit state in process
  memory, so a restart, a rolling deploy, or a second replica each reset the
  budget to zero. These tests assert the replacement does not: the counter is a
  row, every consume is one atomic statement against it, and no process anywhere
  holds a copy.
  """

  use ServiceRadar.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Notifications.NotificationChannel
  alias ServiceRadar.Notifications.NotificationProvider
  alias ServiceRadar.Notifications.RateLimiter
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:notification_rate_limiter_test)
    channel = create_channel!(actor, 3)

    on_exit(fn ->
      RateLimiter.reset(channel.id)
      delete_fixture("notification_channels", channel.id)
      delete_fixture("notification_providers", channel.provider_id)
    end)

    {:ok, actor: actor, channel: channel, now: ~U[2026-08-09 12:34:56.000000Z]}
  end

  describe "budget enforcement" do
    @tag sandbox: :unboxed
    test "a concurrent first insert cannot let the losing caller bypass a one-slot budget", %{
      channel: channel,
      now: now
    } do
      parent = self()

      winner =
        Task.async(fn ->
          Repo.transaction(fn ->
            decision = RateLimiter.check_and_consume(channel.id, 1, now)
            send(parent, :winner_reserved)

            receive do
              :commit_winner -> decision
            end
          end)
        end)

      assert_receive :winner_reserved, 5_000

      loser =
        Task.async(fn ->
          send(parent, :loser_started)
          RateLimiter.check_and_consume(channel.id, 1, now)
        end)

      assert_receive :loser_started, 5_000

      # The losing INSERT must take its statement snapshot while the winner's
      # row is still uncommitted, then block on that row's unique-key lock.
      Process.sleep(100)
      send(winner.pid, :commit_winner)

      assert {:ok, :ok} = Task.await(winner, 5_000)
      assert {:wait, retry_at} = Task.await(loser, 5_000)
      assert DateTime.compare(retry_at, ~U[2026-08-09 12:35:00Z]) == :eq
      assert %{consumed: 1} = RateLimiter.usage(channel.id)
    end

    test "allows exactly the configured number of sends per window", %{
      channel: channel,
      now: now
    } do
      assert RateLimiter.check_and_consume(channel.id, 3, now) == :ok
      assert RateLimiter.check_and_consume(channel.id, 3, now) == :ok
      assert RateLimiter.check_and_consume(channel.id, 3, now) == :ok

      assert {:wait, at} = RateLimiter.check_and_consume(channel.id, 3, now)
      assert DateTime.compare(at, ~U[2026-08-09 12:35:00Z]) == :eq
    end

    test "a refused call does not inflate the counter", %{channel: channel, now: now} do
      for _ <- 1..3, do: RateLimiter.check_and_consume(channel.id, 3, now)
      for _ <- 1..10, do: RateLimiter.check_and_consume(channel.id, 3, now)

      # `consumed` must record sends made under budget, not dispatcher
      # wake-ups; otherwise the number an operator reads is meaningless.
      assert %{consumed: 3} = RateLimiter.usage(channel.id)
    end

    test "the budget refreshes in the next window", %{channel: channel, now: now} do
      for _ <- 1..3, do: RateLimiter.check_and_consume(channel.id, 3, now)
      assert {:wait, _at} = RateLimiter.check_and_consume(channel.id, 3, now)

      next_window = DateTime.add(now, 60, :second)

      assert RateLimiter.check_and_consume(channel.id, 3, next_window) == :ok

      assert %{consumed: 1, window_started_at: rolled} = RateLimiter.usage(channel.id)
      assert DateTime.compare(rolled, ~U[2026-08-09 12:35:00Z]) == :eq
    end

    test "a late caller with an older clock does not roll the window backwards", %{
      channel: channel,
      now: now
    } do
      later = DateTime.add(now, 60, :second)

      assert RateLimiter.check_and_consume(channel.id, 3, later) == :ok
      assert RateLimiter.check_and_consume(channel.id, 3, now) == :ok

      # The straggler consumes from the CURRENT window rather than resetting it,
      # which is what keeps two nodes with skewed clocks from handing each other
      # a fresh budget every tick.
      assert %{consumed: 2, window_started_at: held} = RateLimiter.usage(channel.id)
      assert DateTime.compare(held, ~U[2026-08-09 12:35:00Z]) == :eq
    end

    test "channels have independent budgets", %{actor: actor, channel: channel, now: now} do
      other = create_channel!(actor, 3)
      on_exit(fn -> RateLimiter.reset(other.id) end)

      for _ <- 1..3, do: RateLimiter.check_and_consume(channel.id, 3, now)

      assert {:wait, _at} = RateLimiter.check_and_consume(channel.id, 3, now)
      assert RateLimiter.check_and_consume(other.id, 3, now) == :ok
    end
  end

  describe "restart survival" do
    test "the consumed budget is a database row, not process state", %{
      channel: channel,
      now: now
    } do
      for _ <- 1..2, do: RateLimiter.check_and_consume(channel.id, 3, now)

      {:ok, uuid} = Ecto.UUID.dump(channel.id)

      {:ok, %{rows: rows}} =
        SQL.query(
          Repo,
          "SELECT consumed FROM platform.notification_channel_rate_limits WHERE channel_id = $1",
          [uuid]
        )

      # The evidence of durability is that the state is READABLE BY SQL. A
      # restarted node, a second replica, and an Oban retry on a third all issue
      # exactly this query and see exactly this number; a GenServer's state is
      # visible to none of them.
      assert rows == [[2]]
    end

    test "no supervised process holds the budget" do
      # `ServiceRadar.Security.RateLimiter` IS a process, which is why this
      # checks the notification limiter by name rather than sweeping the
      # registry for anything limiter-shaped.
      refute Process.whereis(RateLimiter)
      refute function_exported?(RateLimiter, :start_link, 1)
      refute function_exported?(RateLimiter, :child_spec, 1)
    end

    test "a fresh caller with no prior state in this process sees the spent budget", %{
      channel: channel,
      now: now
    } do
      for _ <- 1..3, do: RateLimiter.check_and_consume(channel.id, 3, now)

      # A different process is the closest in-test analogue of a restarted node:
      # it shares no memory with the one that spent the budget, only the row.
      # `async: false` puts the sandbox owner in shared mode, so the task reaches
      # the same connection without an explicit allow.
      task = Task.async(fn -> RateLimiter.check_and_consume(channel.id, 3, now) end)

      assert {:wait, _at} = Task.await(task)
    end
  end

  describe "reset/2" do
    test "discards the stored budget", %{channel: channel, now: now} do
      for _ <- 1..3, do: RateLimiter.check_and_consume(channel.id, 3, now)
      assert {:wait, _at} = RateLimiter.check_and_consume(channel.id, 3, now)

      assert RateLimiter.reset(channel.id) == :ok
      assert RateLimiter.usage(channel.id) == nil
      assert RateLimiter.check_and_consume(channel.id, 3, now) == :ok
    end
  end

  # --- fixtures -------------------------------------------------------------

  defp create_channel!(actor, rate_limit) do
    provider = create_provider!(actor)

    {:ok, channel} =
      NotificationChannel
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "channel-#{System.unique_integer([:positive])}",
          provider_id: provider.id,
          config: %{},
          rate_limit_per_minute: rate_limit
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    channel
  end

  defp create_provider!(actor) do
    {:ok, provider} =
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
      |> Ash.create(actor: actor)

    provider
  end

  defp delete_fixture(table, id) do
    case Ecto.UUID.dump(id) do
      {:ok, dumped_id} ->
        _ = SQL.query(Repo, "DELETE FROM platform.#{table} WHERE id = $1", [dumped_id])
        :ok

      :error ->
        :ok
    end
  end
end
