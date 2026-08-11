defmodule ServiceRadar.Notifications.RoutingWorkerTest do
  @moduledoc """
  The routing worker's Oban contract: what its args carry, how a string
  `lifecycle_reason` becomes an atom, and what it does with `route/3`'s two
  lists.

  Three properties are load-bearing and none of them needs a database.

  1. **The args are the routing request key.** `Dedupe.routing_request_key/1` is
     keyed on `{alert_id, lifecycle_reason, step_number, dedupe_key}`, and those
     are exactly the Oban unique keys. If the two ever disagree, two jobs Oban
     considers distinct produce one routing request, or vice versa.
  2. **Suppressed ids are not enqueued and are not an error.** A withheld
     notification is already a fully recorded delivery row carrying its reason
     (design D5). Treating `suppressed` as work would send it anyway; treating it
     as failure would retry the whole routing pass.
  3. **An unknown `lifecycle_reason` never reaches `String.to_atom/1`.** Job args
     are untrusted input under the Iron Laws, and `String.to_existing_atom/1` is
     not a fix - it turns an atom-table question into a crash that depends on
     what else happens to be loaded.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.RoutingWorker

  @alert_id "0197b6f0-0000-7000-8000-0000000000a1"

  # A stand-in dispatcher. It runs in the calling process, so the reply it should
  # give is read from that process's dictionary - which keeps the stub a single
  # module and the suite async.
  defmodule Dispatcher do
    @moduledoc false
    def route(alert_id, reason, opts) do
      send(self(), {:routed, alert_id, reason, opts})
      Process.get(:route_result, {:ok, %{planned: [], suppressed: []}})
    end
  end

  defp routes(result), do: Process.put(:route_result, result)

  defp job(args), do: %Oban.Job{args: args}

  defp fire_args(overrides \\ %{}) do
    Map.merge(
      %{
        "alert_id" => @alert_id,
        "lifecycle_reason" => "fire",
        "step_number" => nil,
        "dedupe_key" => nil
      },
      overrides
    )
  end

  defp recording_enqueue do
    test = self()

    fn delivery_id ->
      send(test, {:enqueued, delivery_id})
      {:ok, %Oban.Job{id: 1}}
    end
  end

  describe "args and job construction" do
    test "args carry the four routing request fields with string keys" do
      assert RoutingWorker.args(@alert_id, :fire) == %{
               "alert_id" => @alert_id,
               "lifecycle_reason" => "fire",
               # Present and nil rather than absent: a key that is sometimes
               # missing computes a different uniqueness digest than the same key
               # set to nil, so two identical requests would not collapse.
               "step_number" => nil,
               "dedupe_key" => nil
             }
    end

    test "step_number and dedupe_key are carried when supplied" do
      assert %{"step_number" => 2, "dedupe_key" => "rule=1|group=a"} =
               RoutingWorker.args(@alert_id, :escalate,
                 step_number: 2,
                 dedupe_key: "rule=1|group=a"
               )
    end

    test "the unique keys are exactly the routing request key" do
      # Dedupe.routing_request_key/1's tuple, not a second identity scheme.
      assert %{keys: keys, period: :infinity} = RoutingWorker.job(@alert_id, :fire).changes.unique

      assert Enum.sort(keys) == [:alert_id, :dedupe_key, :lifecycle_reason, :step_number]
    end

    test "the job lands on the notifications queue and may retry" do
      changes = RoutingWorker.job(@alert_id, :fire).changes

      assert changes.queue == "notifications"
      # Unlike the dispatch worker: nothing else recovers a lost routing
      # request, because design D8 reserves origination for the alert lifecycle.
      assert changes.max_attempts == 3
    end

    test "job options are separated from args options" do
      at = ~U[2026-08-09 12:00:00.000000Z]

      changes = RoutingWorker.job(@alert_id, :escalate, step_number: 3, scheduled_at: at).changes

      assert changes.scheduled_at == at
      assert changes.args["step_number"] == 3
    end
  end

  describe "lifecycle_reason mapping" do
    test "the closed table covers the reasons design D6 names" do
      assert RoutingWorker.lifecycle_reasons() == %{
               "fire" => :fire,
               "renotify" => :renotify,
               "escalate" => :escalate,
               "resolve" => :resolve
             }
    end

    test "a known reason is passed to the dispatcher as an atom" do
      assert :ok =
               RoutingWorker.route(job(fire_args(%{"lifecycle_reason" => "escalate"})),
                 dispatcher: Dispatcher,
                 enqueue: recording_enqueue()
               )

      assert_received {:routed, @alert_id, :escalate, _opts}
    end

    test "an unknown reason is cancelled rather than converted to an atom" do
      assert {:cancel, :unknown_lifecycle_reason} =
               RoutingWorker.route(job(fire_args(%{"lifecycle_reason" => "not_a_reason"})),
                 dispatcher: Dispatcher
               )

      refute_received {:routed, _alert_id, _reason, _opts}
    end

    test "a missing reason is cancelled" do
      assert {:cancel, :unknown_lifecycle_reason} =
               RoutingWorker.route(job(%{"alert_id" => @alert_id}), dispatcher: Dispatcher)
    end

    test "a missing alert id is cancelled" do
      assert {:cancel, :missing_alert_id} =
               RoutingWorker.route(job(%{"lifecycle_reason" => "fire"}), dispatcher: Dispatcher)
    end
  end

  describe "fan-out" do
    test "one dispatch job is enqueued per planned delivery" do
      routes({:ok, %{planned: ["delivery-1", "delivery-2"], suppressed: []}})

      assert :ok =
               RoutingWorker.route(job(fire_args()),
                 dispatcher: Dispatcher,
                 enqueue: recording_enqueue()
               )

      assert_received {:enqueued, "delivery-1"}
      assert_received {:enqueued, "delivery-2"}
    end

    test "suppressed decisions are recorded, never enqueued" do
      # The row already exists with its suppression_reason; there is nothing left
      # to send and nothing was dropped (design D5).
      routes({:ok, %{planned: [], suppressed: ["suppressed-1"]}})

      assert :ok =
               RoutingWorker.route(job(fire_args()),
                 dispatcher: Dispatcher,
                 enqueue: recording_enqueue()
               )

      refute_received {:enqueued, _id}
    end

    test "one failed enqueue does not discard the deliveries queued alongside it" do
      test = self()
      routes({:ok, %{planned: ["delivery-bad", "delivery-good"], suppressed: []}})

      enqueue = fn
        "delivery-bad" ->
          {:error, :oban_unavailable}

        id ->
          send(test, {:enqueued, id})
          {:ok, %Oban.Job{id: 1}}
      end

      # Every planned row is :pending with next_attempt_at set, so the
      # continuation sweeper re-drives whatever could not be queued here.
      assert :ok = RoutingWorker.route(job(fire_args()), dispatcher: Dispatcher, enqueue: enqueue)

      assert_received {:enqueued, "delivery-good"}
    end

    test "step_number and dedupe_key from the args reach route/3" do
      args = fire_args(%{"step_number" => 2, "dedupe_key" => "rule=r1|group=g1"})

      assert :ok = RoutingWorker.route(job(args), dispatcher: Dispatcher)

      assert_received {:routed, @alert_id, :fire, opts}
      assert Keyword.get(opts, :step_number) == 2
      assert Keyword.get(opts, :dedupe_key) == "rule=r1|group=g1"
    end

    test "absent step_number and dedupe_key are not forwarded as nil" do
      # route/3 derives both when they are not supplied; forwarding an explicit
      # nil would override the derivation with "no key".
      assert :ok = RoutingWorker.route(job(fire_args()), dispatcher: Dispatcher)

      assert_received {:routed, @alert_id, :fire, opts}
      refute Keyword.has_key?(opts, :step_number)
      refute Keyword.has_key?(opts, :dedupe_key)
    end

    test "the dispatcher and enqueue seams are not leaked into route/3's options" do
      assert :ok =
               RoutingWorker.route(job(fire_args()),
                 dispatcher: Dispatcher,
                 enqueue: recording_enqueue(),
                 now: ~U[2026-08-09 12:00:00.000000Z]
               )

      assert_received {:routed, @alert_id, :fire, opts}
      refute Keyword.has_key?(opts, :dispatcher)
      refute Keyword.has_key?(opts, :enqueue)
      assert Keyword.get(opts, :now) == ~U[2026-08-09 12:00:00.000000Z]
    end
  end

  describe "failure handling" do
    test "a pruned alert is cancelled, because retrying cannot bring it back" do
      routes({:error, :alert_not_found})

      assert {:cancel, :alert_not_found} =
               RoutingWorker.route(job(fire_args()), dispatcher: Dispatcher)
    end

    test "an invalid routing request is cancelled" do
      routes({:error, :invalid_routing_request})

      assert {:cancel, :invalid_routing_request} =
               RoutingWorker.route(job(fire_args()), dispatcher: Dispatcher)
    end

    test "a transient failure asks Oban to retry, because nothing else routes this alert" do
      routes({:error, {:existing_dispatches_unreadable, :timeout}})

      assert {:error, {:existing_dispatches_unreadable, :timeout}} =
               RoutingWorker.route(job(fire_args()), dispatcher: Dispatcher)
    end
  end
end
