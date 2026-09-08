defmodule ServiceRadar.Notifications.DispatcherEdgeTest do
  @moduledoc """
  Dispatch through an agent: the `:edge_agent` route and `:control_plane`
  plugin execution (tasks 3.3.1, 3.4.1, 3.4.2, 3.4.3, 3.4.4).

  Both routes take the SAME `plugin.run_action` path and differ only in which
  agent they address, which is what makes there be exactly one Wasm host in the
  product. What is asserted here is the behaviour that only shows up during an
  incident, when nobody is watching the code:

    * an offline agent is RETRYABLE, not an immediate failover. `AgentCommandBus`
      is at-most-once with no store-and-forward, so the delivery row is the
      outbox (design R2, forgejo #4902); failing over on the first offline reply
      abandons a site that was briefly disconnected, which is exactly the
      disconnect an escalation ladder exists to survive.
    * failover is ONE hop, only after the budget is spent, and never for a
      `fail_closed` channel.
    * the command result is a wake-up signal; the delivery row is the record.
      `Dispatcher.reconcile/2` closes out a row whose signal was lost using the
      `agent_commands` row core itself wrote - no dependency on
      `:status_handler_enabled`. A result that is lost for good still reaches a
      TERMINAL state (tasks 3.9.4), by the receipt sweep when the command row
      can be read and by the receipt timeout when it cannot.
    * a configuration failure (unapproved package, missing assignment,
      unconfigured platform agent) is PERMANENT, so it burns no budget waiting
      for a retry that cannot help.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Notifications.Dispatcher
  alias ServiceRadar.Notifications.NotificationChannel
  alias ServiceRadar.Notifications.NotificationDelivery
  alias ServiceRadar.Notifications.NotificationEscalationPolicy
  alias ServiceRadar.Notifications.NotificationEscalationStep
  alias ServiceRadar.Notifications.NotificationEscalationStepChannel
  alias ServiceRadar.Notifications.NotificationProvider
  alias ServiceRadar.Notifications.NotificationRoute
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  @assignment_id "33333333-3333-3333-3333-333333333333"

  defmodule StubBus do
    @moduledoc """
    An `AgentCommandBus` that answers from the calling process's dictionary.
    The dispatcher calls it inline, so no supervision and no mock library.
    """

    def dispatch(agent_uid, command_type, payload, opts) do
      Process.put(
        :bus_calls,
        [%{agent_uid: agent_uid, command_type: command_type, payload: payload, opts: opts}] ++
          Process.get(:bus_calls, [])
      )

      Process.get(:bus_result) || {:ok, Keyword.fetch!(opts, :command_id)}
    end

    def calls, do: Enum.reverse(Process.get(:bus_calls, []))
    def answer_with(result), do: Process.put(:bus_result, result)
  end

  defmodule StubTarget do
    @moduledoc "A `PluginTarget` answering from the calling process's dictionary."

    def resolve(channel, _provider, _opts) do
      Process.get(:target_result) ||
        {:ok,
         %{
           agent_uid: agent_uid(channel),
           partition_id: nil,
           plugin_assignment_id: "33333333-3333-3333-3333-333333333333",
           plugin_package_id: "11111111-1111-1111-1111-111111111111",
           notification_entrypoint: "notify_pagerduty",
           notification_capabilities: ["send", "test", "resolve_update"],
           credential_requirements: %{},
           execution_route: channel.execution_route
         }}
    end

    defp agent_uid(%{execution_route: :edge_agent, agent_uid: uid}), do: uid
    defp agent_uid(_channel), do: "k8s-agent"

    def answer_with(result), do: Process.put(:target_result, result)
  end

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    Process.delete(:bus_calls)
    Process.delete(:bus_result)
    Process.delete(:target_result)

    {:ok, actor: SystemActor.system(:notification_edge_test)}
  end

  defp deliver(id, actor, now, opts \\ []) do
    Dispatcher.deliver(
      id,
      Keyword.merge(
        [actor: actor, now: now, command_bus: StubBus, plugin_target: StubTarget],
        opts
      )
    )
  end

  # --- 3.3.1: control-plane plugin execution ---------------------------------

  describe ":control_plane + :wasm_plugin (tasks 3.3.1)" do
    test "dispatches plugin.run_action to the platform-resident agent", %{actor: actor} do
      %{id: id, now: now} = planned!(actor, execution_route: :control_plane)

      assert {:ok, :dispatching} = deliver(id, actor, now)

      assert [call] = StubBus.calls()
      assert call.agent_uid == "k8s-agent"
      # The same command as any edge dispatch: one Wasm host, addressed twice.
      assert call.command_type == "plugin.run_action"
      assert call.payload["execution_route"] == "control_plane"
      assert call.payload["schema"] == Dispatcher.edge_command_schema()
      assert call.payload["entrypoint"] == "notify_pagerduty"
      assert call.payload["intent"] == "send"
      assert call.payload["command_id"] == call.opts[:command_id]
      assert call.opts[:notification_delivery_attempt]
    end

    test "names the assignment the agent will run under", %{actor: actor} do
      %{id: id, now: now} = planned!(actor, execution_route: :control_plane)

      assert {:ok, :dispatching} = deliver(id, actor, now)

      assert [call] = StubBus.calls()
      # go/pkg/agent refuses a plugin.run_action payload with no assignment id
      # before it looks at anything else; the assignment, not the package,
      # carries the narrowed capability set the module runs under.
      assert call.payload["plugin_assignment_id"] == @assignment_id
      assert call.payload["action_key"] == "pagerduty"
    end

    test "an unresolvable target fails permanently rather than retrying", %{actor: actor} do
      %{id: id, now: now} = planned!(actor, execution_route: :control_plane, max_attempts: 5)

      StubTarget.answer_with(
        {:error, {"plugin_package_unapproved", "acme@1.0.0 is revoked; only an approved package"}}
      )

      assert {:error, {:delivery_failed, "plugin_package_unapproved"}} = deliver(id, actor, now)

      delivery = reload!(id, actor)
      # Terminal on the FIRST attempt despite four remaining: no number of
      # retries approves a package, and the useful behaviour is to fail over.
      assert delivery.state == :failed
      assert delivery.attempt_count == 1
      assert StubBus.calls() == []
    end
  end

  # --- 3.4.1 / 3.4.2: offline and failover -----------------------------------

  describe "an offline agent (tasks 3.4.1)" do
    test "is retryable and leaves the delivery pending", %{actor: actor} do
      %{id: id, now: now} = planned!(actor, execution_route: :edge_agent, agent_uid: "site-1")
      StubBus.answer_with({:error, {:agent_offline, "site-1"}})

      assert {:retry, at} = deliver(id, actor, now)

      delivery = reload!(id, actor)
      assert delivery.state == :pending
      assert delivery.attempt_count == 1
      assert delivery.error_class == "agent_offline"
      assert DateTime.after?(at, now)
      assert DateTime.after?(delivery.next_attempt_at, now)
    end

    test "does not fail over while the retry budget is unspent", %{actor: actor} do
      %{id: id, now: now, channel: channel} =
        planned!(actor, execution_route: :edge_agent, agent_uid: "site-1", max_attempts: 3)

      fallback = create_fallback!(actor)
      set_fallback!(channel, fallback, actor)
      StubBus.answer_with({:error, {:agent_offline, "site-1"}})

      assert {:retry, _at} = deliver(id, actor, now)

      # Abandoning a site on its first missed heartbeat is the failure R2 calls
      # out by name.
      assert successors(id, actor) == []
    end

    test "any other bus error is retryable too", %{actor: actor} do
      %{id: id, now: now} = planned!(actor, execution_route: :edge_agent, agent_uid: "site-1")
      StubBus.answer_with({:error, :control_session_unavailable})

      assert {:retry, _at} = deliver(id, actor, now)
      assert reload!(id, actor).error_class == "agent_command_failed"
    end
  end

  describe "failover after the budget is spent (tasks 3.4.2)" do
    test "takes exactly one hop and back-references its origin", %{actor: actor} do
      %{id: id, now: now, channel: channel} =
        planned!(actor, execution_route: :edge_agent, agent_uid: "site-1", max_attempts: 1)

      fallback = create_fallback!(actor)
      set_fallback!(channel, fallback, actor)
      StubBus.answer_with({:error, {:agent_offline, "site-1"}})

      assert {:error, {:delivery_failed, "agent_offline"}} = deliver(id, actor, now)

      assert reload!(id, actor).state == :failed
      assert [successor] = successors(id, actor)
      assert successor.channel_id == fallback.id
      assert successor.state == :pending
      assert successor.originating_delivery_id == id
    end

    test "a fail_closed channel never fails over", %{actor: actor} do
      %{id: id, now: now, channel: channel} =
        planned!(actor,
          execution_route: :edge_agent,
          agent_uid: "site-1",
          max_attempts: 1,
          fail_closed: true
        )

      fallback = create_fallback!(actor)
      set_fallback!(channel, fallback, actor)
      StubBus.answer_with({:error, {:agent_offline, "site-1"}})

      assert {:error, {:delivery_failed, "agent_offline"}} = deliver(id, actor, now)

      # fail_closed is the setting for a destination whose whole purpose is that
      # it must not be silently substituted.
      assert reload!(id, actor).state == :failed
      assert successors(id, actor) == []
    end
  end

  # --- 3.4.3: the delivery row is the record ---------------------------------

  describe "the delivery row is the system of record (tasks 3.4.3)" do
    test "records the command id and the agent it went to", %{actor: actor} do
      %{id: id, now: now} = planned!(actor, execution_route: :edge_agent, agent_uid: "site-1")

      assert {:ok, :dispatching} = deliver(id, actor, now)

      assert [call] = StubBus.calls()
      delivery = reload!(id, actor)
      assert delivery.state == :dispatching
      assert delivery.command_id == call.opts[:command_id]
      assert is_nil(delivery.external_correlation_id)
      assert delivery.execution_route == :edge_agent
      assert delivery.agent_uid == "site-1"
      assert delivery.attempt_count == 0
    end

    test "no secret material crosses into the command payload", %{actor: actor} do
      %{id: id, now: now} = planned!(actor, execution_route: :edge_agent, agent_uid: "site-1")

      assert {:ok, :dispatching} = deliver(id, actor, now)

      assert [call] = StubBus.calls()
      keys = Map.keys(call.payload)
      # Secrets reach an agent through CredentialBrokerGrant host-side injection
      # or the trusted-host-only host_params_json, never through params_json.
      refute "secrets" in keys
      refute "secret_refs" in keys
      refute "config" in keys
      assert call.payload["channel_config"] == %{}
      assert call.payload["rendered_payload"] != %{}
      assert call.payload["alert_snapshot"]["id"]
      assert call.payload["attempt_count"] == 1
    end
  end

  # --- 3.4.4 / 3.4.5: reconcile ----------------------------------------------

  describe "reconcile/2 settles a lost wake-up signal (tasks 3.4.4)" do
    test "a completed command settles the delivery as sent without re-sending", %{actor: actor} do
      %{id: id, now: now} = planned!(actor, execution_route: :edge_agent, agent_uid: "site-1")
      command = create_command!(actor, "site-1")
      dispatching!(id, command.id, actor)
      complete!(command, id, actor)

      assert %{settled: settled} = Dispatcher.reconcile(now, actor: actor)
      assert id in settled

      delivery = reload!(id, actor)
      assert delivery.state == :sent
      assert delivery.result_summary["receipt"] == "delivered"
      # The point of reading the command row: the stall sweep would have
      # re-dispatched this and sent a second notification.
      assert StubBus.calls() == []
    end

    test "a failed command hands the delivery back to the retry budget", %{actor: actor} do
      %{id: id, now: now} =
        planned!(actor, execution_route: :edge_agent, agent_uid: "site-1", max_attempts: 3)

      command = create_command!(actor, "site-1")
      dispatching!(id, command.id, actor)
      retryable!(command, id, actor)

      assert %{settled: settled} = Dispatcher.reconcile(now, actor: actor)
      assert id in settled

      delivery = reload!(id, actor)
      assert delivery.state == :pending
      assert delivery.error_class == "provider_busy"
      assert delivery.attempt_count == 1
    end

    test "a guest-declared permanent failure terminates without spending the retry budget", %{
      actor: actor
    } do
      %{id: id, now: now} =
        planned!(actor, execution_route: :edge_agent, agent_uid: "site-1", max_attempts: 5)

      command = create_command!(actor, "site-1")
      dispatching!(id, command.id, actor)
      permanent!(command, id, actor)

      assert %{settled: settled} = Dispatcher.reconcile(now, actor: actor)
      assert id in settled

      delivery = reload!(id, actor)
      assert delivery.state == :failed
      assert delivery.error_class == "invalid_destination"
      assert delivery.attempt_count == 1
    end

    test "an in-flight command inside its TTL is left alone", %{actor: actor} do
      %{id: id, now: now} = planned!(actor, execution_route: :edge_agent, agent_uid: "site-1")
      command = create_command!(actor, "site-1")
      dispatching!(id, command.id, actor)

      assert %{settled: []} = Dispatcher.reconcile(now, actor: actor)
      assert reload!(id, actor).state == :dispatching
    end

    test "a command past its own TTL with no result is owed another attempt", %{actor: actor} do
      %{id: id, now: now} =
        planned!(actor, execution_route: :edge_agent, agent_uid: "site-1", max_attempts: 3)

      command = create_command!(actor, "site-1")
      dispatching!(id, command.id, actor)

      # `expires_at` is written by core at dispatch, so this decision needs
      # nothing from the status handler.
      later = DateTime.add(now, 3_600, :second)

      assert %{settled: settled} = Dispatcher.reconcile(later, actor: actor)
      assert id in settled

      delivery = reload!(id, actor)
      assert delivery.state == :pending
      assert delivery.error_class == "command_receipt_timeout"
    end
  end

  describe "reconcile/2 drains an agent that came back (tasks 3.4.5)" do
    test "names a backed-off delivery whose agent has a control session", %{actor: actor} do
      %{id: id, now: now} =
        planned!(actor, execution_route: :edge_agent, agent_uid: "site-1", max_attempts: 3)

      StubBus.answer_with({:error, {:agent_offline, "site-1"}})
      assert {:retry, _at} = deliver(id, actor, now)

      assert %{drain: drain} =
               Dispatcher.reconcile(now, actor: actor, agent_online?: fn _uid -> true end)

      assert id in drain
    end

    test "leaves it alone while the agent is still offline", %{actor: actor} do
      %{id: id, now: now} =
        planned!(actor, execution_route: :edge_agent, agent_uid: "site-1", max_attempts: 3)

      StubBus.answer_with({:error, {:agent_offline, "site-1"}})
      assert {:retry, _at} = deliver(id, actor, now)

      assert %{drain: drain} =
               Dispatcher.reconcile(now, actor: actor, agent_online?: fn _uid -> false end)

      refute id in drain
    end
  end

  # --- 3.9.4: a lost result cannot strand a page -----------------------------

  describe "a lost command result still reaches a terminal state (tasks 3.9.4)" do
    test "the last attempt is failed by the sweep and the page moves to the fallback", %{
      actor: actor
    } do
      %{id: id, now: now, channel: channel} =
        planned!(actor, execution_route: :edge_agent, agent_uid: "site-1", max_attempts: 1)

      fallback = create_fallback!(actor)
      set_fallback!(channel, fallback, actor)

      command = create_command!(actor, "site-1")
      dispatching!(id, command.id, actor)

      # No ack, no progress, no result, ever. The bus is at-most-once with no
      # store-and-forward (forgejo #4902), so once the TTL passes there is
      # nothing left to wait for and nothing else in the system will move this
      # row: `read :retry_due` selects only `:pending`.
      later = DateTime.add(now, 3_600, :second)

      assert %{settled: settled} = Dispatcher.reconcile(later, actor: actor)
      assert id in settled

      delivery = reload!(id, actor)
      assert delivery.state == :failed
      assert delivery.error_class == "command_receipt_timeout"

      # Terminal is not the same as delivered, and that is the point. `:failed`
      # is what failover keys off, so a lost result costs one channel rather
      # than the page: a row parked in `:dispatching` would have notified
      # nobody and told nobody it had not.
      assert [successor] = successors(id, actor)
      assert successor.channel_id == fallback.id
      assert successor.originating_delivery_id == id

      # The sweep also converges. A settled row is out of the `:dispatching`
      # scan, so the next pass is not a second failover.
      assert %{settled: []} = Dispatcher.reconcile(later, actor: actor)
      assert reload!(id, actor).state == :failed
      assert successors(id, actor) == [successor]
    end

    test "a delivery whose command row is unreadable is settled by the receipt timeout", %{
      actor: actor
    } do
      %{id: id, now: now} =
        planned!(actor, execution_route: :edge_agent, agent_uid: "site-1", max_attempts: 3)

      # The other way a result is lost: not "no answer yet" but "nothing left to
      # ask". The row still has to converge within the ordinary attempt budget;
      # redispatching it directly from due/2 would duplicate an in-flight page.
      dispatching!(id, Ash.UUID.generate(), actor)

      later = DateTime.add(now, 3_600, :second)

      assert %{settled: settled} = Dispatcher.reconcile(later, actor: actor)
      assert id in settled
      assert reload!(id, actor).state == :pending
      assert reload!(id, actor).error_class == "command_receipt_unavailable"

      assert %{retry: retry} = Dispatcher.due(later, actor: actor)
      refute id in retry
    end
  end

  # --- fixtures --------------------------------------------------------------

  defp planned!(actor, channel_opts) do
    channel = create_channel!(actor, channel_opts)
    policy = create_policy!(actor)
    step = create_step!(actor, policy)
    attach!(actor, step, channel)
    create_route!(actor, policy)

    alert = create_alert!(actor)
    now = DateTime.add(alert.triggered_at, 1, :second)

    assert {:ok, %{planned: [id]}} = Dispatcher.route(alert.id, :fire, actor: actor, now: now)

    %{id: id, alert: alert, channel: channel, now: now}
  end

  defp reload!(id, actor) do
    NotificationDelivery
    |> Ash.Query.for_read(:by_id, %{id: id})
    |> Ash.read_one!(actor: actor)
  end

  defp successors(id, actor) do
    NotificationDelivery
    |> Ash.Query.for_read(:for_originating_delivery, %{originating_delivery_id: id})
    |> Ash.read!(actor: actor)
  end

  defp dispatching!(id, command_id, actor) do
    id
    |> reload!(actor)
    |> Ash.Changeset.for_update(:record_dispatching, %{command_id: command_id}, actor: actor)
    |> Ash.update!(actor: actor)
  end

  defp create_command!(actor, agent_uid) do
    AgentCommand
    |> Ash.Changeset.for_create(
      :create,
      %{
        command_type: "plugin.run_action",
        agent_id: agent_uid,
        partition_id: "default",
        payload: %{},
        ttl_seconds: 60
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp complete!(command, delivery_id, actor) do
    command
    |> Ash.Changeset.for_update(:mark_sent, %{}, actor: actor)
    |> Ash.update!(actor: actor)
    |> Ash.Changeset.for_update(
      :complete,
      %{
        result_payload: %{
          "schema" => "serviceradar.notification_delivery_result.v1",
          "delivery_id" => delivery_id,
          "status" => "delivered",
          "external_correlation_id" => "provider-message-1"
        }
      },
      actor: actor
    )
    |> Ash.update!(actor: actor)
  end

  defp retryable!(command, delivery_id, actor) do
    command
    |> Ash.Changeset.for_update(
      :fail,
      %{
        failure_reason: "notifier returned 500",
        result_payload: %{
          "schema" => "serviceradar.notification_delivery_result.v1",
          "delivery_id" => delivery_id,
          "status" => "retryable",
          "error_class" => "provider_busy",
          "error_message" => "provider returned 500",
          "retry_after_seconds" => 30
        }
      },
      actor: actor
    )
    |> Ash.update!(actor: actor)
  end

  defp permanent!(command, delivery_id, actor) do
    command
    |> Ash.Changeset.for_update(
      :fail,
      %{
        failure_reason: "notifier rejected destination",
        result_payload: %{
          "schema" => "serviceradar.notification_delivery_result.v1",
          "delivery_id" => delivery_id,
          "status" => "failed",
          "error_class" => "invalid_destination",
          "error_message" => "the configured destination does not exist"
        }
      },
      actor: actor
    )
    |> Ash.update!(actor: actor)
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

  defp create_package!(actor) do
    plugin_id = "acme-notifier-#{System.unique_integer([:positive])}"

    manifest = %{
      "id" => plugin_id,
      "name" => "Acme Notifier",
      "version" => "1.0.0",
      "entrypoint" => "run_check",
      "runtime" => "wasi-preview1",
      "outputs" => "serviceradar.plugin_result.v1",
      "capabilities" => ["get_config", "log", "http_request", "notify:v1"],
      "resources" => %{"requested_memory_mb" => 32, "requested_cpu_ms" => 5000},
      "notifications" => [
        %{
          "key" => "pagerduty",
          "display_name" => "Acme PagerDuty",
          "entrypoint" => "notify_pagerduty",
          "capabilities" => ["send", "test"],
          "payload_formats" => ["json"]
        }
      ]
    }

    Plugin
    |> Ash.Changeset.for_create(:create, %{plugin_id: plugin_id, name: "Acme Notifier"},
      actor: actor
    )
    |> Ash.create!(actor: actor)

    PluginPackage
    |> Ash.Changeset.for_create(
      :create,
      %{
        plugin_id: plugin_id,
        name: "Acme Notifier",
        version: "1.0.0",
        entrypoint: "run_check",
        runtime: "wasi-preview1",
        outputs: "serviceradar.plugin_result.v1",
        manifest: manifest,
        content_hash: "sha256:#{plugin_id}",
        source_type: :upload
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
    |> Ash.Changeset.for_update(
      :approve,
      %{approved_capabilities: ["get_config", "log", "http_request", "notify:v1"]},
      actor: actor
    )
    |> Ash.update!(actor: actor)
  end

  defp create_provider!(actor) do
    package = create_package!(actor)

    NotificationProvider
    |> Ash.Changeset.for_create(
      :create,
      %{
        provider_key: "acme-#{System.unique_integer([:positive])}",
        provider_type: :wasm_plugin,
        display_name: "Acme Notifier",
        capabilities: [:send, :test],
        supported_routes: [:control_plane, :edge_agent],
        payload_formats: [:json],
        config_schema: %{},
        plugin_package_id: package.id,
        action_key: "pagerduty"
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
    |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
    |> Ash.update!(actor: actor)
  end

  defp create_channel!(actor, opts) do
    provider = create_provider!(actor)

    attrs =
      opts
      |> Map.new()
      |> Map.merge(%{
        name: "channel-#{System.unique_integer([:positive])}",
        provider_id: provider.id,
        config: %{}
      })

    # `partition_id` on an edge channel is mTLS-derived and force-bound from the
    # agent's authenticated control session, never accepted as input, so an
    # edge channel is only creatable while that session exists.
    if attrs[:execution_route] == :edge_agent do
      register_control_session!(attrs.agent_uid, "default")
    end

    NotificationChannel
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp register_control_session!(agent_uid, partition_id) do
    ProcessRegistry.register(
      {:agent_control, partition_id, agent_uid, node()},
      %{
        agent_id: agent_uid,
        partition_id: partition_id,
        gateway_node: node(),
        capabilities: ["wasm"]
      }
    )

    await_control_session(agent_uid, partition_id, 40)
  end

  defp await_control_session(_agent_uid, _partition_id, 0),
    do: flunk("control-session partition did not converge")

  defp await_control_session(agent_uid, partition_id, attempts) do
    case AgentCommandBus.resolve_control_session_evidence(partition_id, agent_uid, nil) do
      {:ok, %{agent_id: ^agent_uid, partition_id: ^partition_id}} ->
        :ok

      _other ->
        Process.sleep(10)
        await_control_session(agent_uid, partition_id, attempts - 1)
    end
  end

  defp create_fallback!(actor) do
    create_channel!(actor, execution_route: :control_plane)
  end

  defp set_fallback!(channel, fallback, actor) do
    channel
    |> Ash.Changeset.for_update(:update, %{fallback_channel_id: fallback.id}, actor: actor)
    |> Ash.update!(actor: actor)
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

  defp create_step!(actor, policy) do
    NotificationEscalationStep
    |> Ash.Changeset.for_create(
      :create,
      %{policy_id: policy.id, step_number: 1, delay_seconds: 0, condition: :always},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp attach!(actor, step, channel) do
    NotificationEscalationStepChannel
    |> Ash.Changeset.for_create(:attach, %{step_id: step.id, channel_id: channel.id},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_route!(actor, policy) do
    NotificationRoute
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "route-#{System.unique_integer([:positive])}",
        escalation_policy_id: policy.id,
        match_expression: %{}
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
