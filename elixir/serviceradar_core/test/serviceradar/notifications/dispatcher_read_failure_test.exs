defmodule ServiceRadar.Notifications.DispatcherReadFailureTest do
  @moduledoc """
  Decision-critical reads fail closed before routing persistence or delivery
  egress. The loader seams keep these regressions database-free: an unavailable
  table is different from a successful read that found no row.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.Dispatcher

  @moduletag :db_free

  @now ~U[2026-08-11 12:00:00Z]

  defmodule NeverTransport do
    @moduledoc false
    @behaviour ServiceRadar.Notifications.Transport

    @impl true
    def capabilities, do: [:send, :test]

    @impl true
    def validate_config(_config), do: :ok

    @impl true
    def deliver(_request, _opts) do
      send(self(), :transport_called)
      ServiceRadar.Notifications.Transport.Result.delivered()
    end

    @impl true
    def test(request, opts), do: deliver(request, opts)
  end

  describe "route/3 preflight reads" do
    test "an alert read failure aborts before any routing decision" do
      opts =
        route_opts(
          load_alert: fn _alert_id, _actor -> {:error, :database_down} end,
          load_enabled_routes: fn _actor ->
            send(self(), :route_read_attempted)
            {:ok, []}
          end
        )

      assert {:error, :database_down} = Dispatcher.route("alert-1", :fire, opts)
      refute_received :route_read_attempted
      refute_received :delivery_write_attempted
    end

    test "an enabled-route read failure is not recorded as no_matching_route" do
      assert {:error, {:enabled_routes_unreadable, :database_down}} =
               Dispatcher.route(
                 "alert-1",
                 :fire,
                 route_opts(load_enabled_routes: fn _actor -> {:error, :database_down} end)
               )

      refute_received :delivery_write_attempted
    end

    test "a rule read failure aborts before route matching and persistence" do
      assert {:error, {:alert_rule_unreadable, "rule-1", :database_down}} =
               Dispatcher.route(
                 "alert-1",
                 :fire,
                 route_opts(load_rule: fn _alert, _actor -> {:error, :database_down} end)
               )

      refute_received :delivery_write_attempted
    end

    test "a silence read failure cannot fail open and page" do
      assert {:error, {:active_silences_unreadable, :database_down}} =
               Dispatcher.route(
                 "alert-1",
                 :fire,
                 route_opts(load_active_silences: fn _now, _actor -> {:error, :database_down} end)
               )

      refute_received :delivery_write_attempted
    end
  end

  describe "deliver/2 suppression preflight reads" do
    test "each database failure aborts before transport egress" do
      cases = [
        {:load_route, fn _route_id, _actor -> {:error, :database_down} end,
         {:notification_route_unreadable, "route-1", :database_down}},
        {:load_step, fn _policy_id, _step_number, _actor -> {:error, :database_down} end,
         {:escalation_step_unreadable, "policy-1", 1, :database_down}},
        {:load_delivery_alert, fn _delivery, _actor -> {:error, :database_down} end,
         {:delivery_alert_unreadable, "alert-1", :database_down}},
        {:load_rule, fn _alert, _actor -> {:error, :database_down} end,
         {:alert_rule_unreadable, "rule-1", :database_down}},
        {:load_active_silences, fn _now, _actor -> {:error, :database_down} end,
         {:active_silences_unreadable, :database_down}},
        {:load_last_dispatch_at, fn _delivery, _actor -> {:error, :database_down} end,
         {:last_dispatch_unreadable, "delivery-1", :database_down}}
      ]

      Enum.each(cases, fn {seam, loader, expected} ->
        opts = Keyword.put(delivery_opts(), seam, loader)

        assert {:error, ^expected} = Dispatcher.deliver("delivery-1", opts)
        refute_received :transport_called
      end)
    end

    test "successful reads that find no optional row continue to the next check" do
      opts =
        delivery_opts(
          load_route: fn _route_id, _actor -> {:ok, nil} end,
          load_step: fn _policy_id, _step_number, _actor -> {:ok, nil} end,
          load_delivery_alert: fn _delivery, _actor -> {:ok, nil} end,
          load_rule: fn _alert, _actor -> {:ok, nil} end,
          load_active_silences: fn _now, _actor -> {:ok, []} end,
          load_last_dispatch_at: fn _delivery, _actor -> {:error, :sentinel_failure} end
        )

      assert {:error, {:last_dispatch_unreadable, "delivery-1", :sentinel_failure}} =
               Dispatcher.deliver("delivery-1", opts)

      refute_received :transport_called
    end
  end

  defp route_opts(overrides) do
    alert = %{
      id: "alert-1",
      device: nil,
      metadata: %{"incident_rule_id" => "rule-1"}
    }

    Keyword.merge(
      [
        now: @now,
        actor: :test_actor,
        load_alert: fn "alert-1", :test_actor -> {:ok, alert} end,
        load_enabled_routes: fn :test_actor -> {:ok, []} end,
        load_rule: fn ^alert, :test_actor -> {:ok, nil} end,
        load_active_silences: fn _now, :test_actor -> {:ok, []} end,
        create_delivery: fn _action, _attrs, _actor ->
          send(self(), :delivery_write_attempted)
          {:error, :unexpected_write}
        end
      ],
      overrides
    )
  end

  defp delivery_opts(overrides \\ []) do
    provider = %{id: "provider-1", status: :active}

    channel = %{
      id: "channel-1",
      enabled: true,
      provider: provider
    }

    alert = %{
      id: "alert-1",
      status: :pending,
      device: nil,
      metadata: %{"incident_rule_id" => "rule-1"}
    }

    delivery = %{
      id: "delivery-1",
      state: :pending,
      next_attempt_at: @now,
      channel: channel,
      channel_id: "channel-1",
      route_id: "route-1",
      policy_id: "policy-1",
      step_number: 1,
      alert_id: "alert-1",
      dedupe_key: "dedupe-1",
      alert_snapshot: %{"id" => "alert-1"}
    }

    Keyword.merge(
      [
        now: @now,
        actor: :test_actor,
        transport: NeverTransport,
        load_delivery: fn "delivery-1", :test_actor -> {:ok, delivery} end,
        load_route: fn "route-1", :test_actor -> {:ok, %{id: "route-1", schedule: nil}} end,
        load_step: fn "policy-1", 1, :test_actor ->
          {:ok, %{step_number: 1, condition: :always}}
        end,
        load_delivery_alert: fn ^delivery, :test_actor -> {:ok, alert} end,
        load_rule: fn ^alert, :test_actor -> {:ok, nil} end,
        load_active_silences: fn _now, :test_actor -> {:ok, []} end,
        load_last_dispatch_at: fn ^delivery, :test_actor -> {:ok, nil} end
      ],
      overrides
    )
  end
end
