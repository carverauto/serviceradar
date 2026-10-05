defmodule ServiceRadarWebNGWeb.DashboardFrameChannelLiveDbTest do
  @moduledoc """
  Database-backed coverage for the dashboard channel: frame streaming, Arrow IPC,
  cursor paging, refresh recovery, caching, token validation and access grants,
  plus plugin-action and live-event paths.
  """

  use ServiceRadarWebNG.DataCase, async: false

  import Phoenix.ChannelTest

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Northbound.ActionInvocation
  alias ServiceRadar.Dashboards.DashboardInstance
  alias ServiceRadar.Dashboards.DashboardInstanceAccessGrant
  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadar.Events.PubSub, as: EventsPubSub
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.Users
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNG.AshTestHelpers
  alias ServiceRadarWebNGWeb.DashboardFrameChannel
  alias ServiceRadarWebNGWeb.DashboardFrameChannel.ActionConfirmations
  alias ServiceRadarWebNGWeb.UserSocket

  @moduletag :web_ng_shared_fixture_db

  @endpoint ServiceRadarWebNGWeb.Endpoint
  @action_id "northbound:showcase-fault"
  @confirm_action_id "northbound:showcase-reset"
  @data_frames [%{"id" => "rows", "query" => "in:dashboard_live_rows", "encoding" => "json_rows", "limit" => 1}]

  defmodule FakeSRQL do
    @moduledoc false

    def query("in:test_rows", _opts) do
      notify_query("in:test_rows")
      {:ok, %{"results" => [%{"id" => "row-1", "value" => 7}], "pagination" => %{"limit" => 1}}}
    end

    def query("in:test_paged_rows", opts) do
      notify_query({"in:test_paged_rows", Map.get(opts, :cursor)})
      id = if Map.get(opts, :cursor) == "page-two", do: "row-2", else: "row-1"

      {:ok,
       %{
         "results" => [%{"id" => id, "value" => 7}],
         "pagination" => %{"next_cursor" => "page-two", "prev_cursor" => Map.get(opts, :cursor), "limit" => 1}
       }}
    end

    def query("in:test_optional_rows", _opts) do
      notify_query("in:test_optional_rows")
      {:ok, %{"results" => [%{"id" => "row-optional", "value" => 9}], "pagination" => %{"limit" => 1}}}
    end

    def query("in:test_flaky_rows", _opts) do
      notify_query("in:test_flaky_rows")

      case Application.get_env(:serviceradar_web_ng, :dashboard_frame_flaky_mode) do
        :error -> {:error, :flaky_error}
        _ -> {:ok, %{"results" => [%{"id" => "row-good", "value" => 13}], "pagination" => %{"limit" => 1}}}
      end
    end

    def query("in:test_slow_rows", _opts) do
      if pid = Application.get_env(:serviceradar_web_ng, :dashboard_frame_test_pid) do
        send(pid, {:srql_query_started, "in:test_slow_rows", self()})
      end

      receive do
        :release_dashboard_frame_query ->
          {:ok, %{"results" => [%{"id" => "row-slow", "value" => 11}], "pagination" => %{"limit" => 1}}}
      after
        5_000 ->
          {:error, :timeout}
      end
    end

    def query(_query, _opts), do: {:ok, %{"results" => [], "pagination" => %{"limit" => 1}}}

    def query_arrow("in:test_arrow", _opts) do
      {:ok, %{payload: "arrow bytes", schema: %{"columns" => ["id"]}}}
    end

    defp notify_query(query) do
      if pid = Application.get_env(:serviceradar_web_ng, :dashboard_frame_test_pid) do
        send(pid, {:srql_query, query})
      end
    end
  end

  defmodule FakeCatalog do
    @moduledoc false
    def eligible_device_actions(_scope) do
      [
        %{
          id: "northbound:showcase-fault",
          descriptor_id: nil,
          label: "Inject fault",
          description: "Forces a transient fault.",
          provider_type: "wasm_plugin",
          provider_name: "showcase",
          scope: "device",
          destination: nil,
          input_schema: %{},
          safety_classification: "mutating",
          requires_confirmation: false,
          timeout_seconds: 30,
          metadata: %{"plugin_id" => "showcase-ot"}
        },
        %{
          id: "northbound:showcase-reset",
          descriptor_id: "018f0000-cafe-7000-8000-000000000001",
          label: "Reset controller",
          description: "Power-cycles the controller.",
          provider_type: "wasm_plugin",
          provider_name: "showcase",
          scope: "device",
          destination: nil,
          input_schema: %{"type" => "object", "properties" => %{"reason" => %{"type" => "string"}}},
          safety_classification: "destructive",
          requires_confirmation: true,
          timeout_seconds: 30,
          metadata: %{"plugin_id" => "showcase-ot"}
        }
      ]
    end

    def eligible_interface_actions(_scope), do: []
  end

  # Stands in for the provider dispatcher, which needs a live agent. It persists
  # a real invocation row so the channel's progress polling reads it through the
  # invocation resource's own read policy.
  defmodule RecordingInvocationService do
    @moduledoc false
    def create_and_dispatch(attrs, opts) do
      send(Application.fetch_env!(:serviceradar_web_ng, :dashboard_live_test_pid), {:invocation_requested, attrs, opts})
      system = AshTestHelpers.system_actor()

      ActionInvocation
      |> Ash.Changeset.for_create(
        :create,
        %{
          action_id: "showcase.fault",
          source: :user,
          target_snapshots: Enum.map(attrs.targets, &Map.new(&1, fn {key, value} -> {to_string(key), value} end)),
          input_values: attrs.input_values,
          metadata: attrs.metadata
        },
        actor: system
      )
      |> Ash.create!()
      |> Ash.Changeset.for_update(:record_dispatch, %{}, actor: system)
      |> Ash.update()
    end
  end

  setup do
    previous =
      Map.new(
        [
          :srql_module,
          :northbound_catalog_module,
          :northbound_invocation_service_module,
          :dashboard_frame_flaky_mode,
          :dashboard_frame_test_pid
        ],
        fn key ->
          {key, Application.get_env(:serviceradar_web_ng, key)}
        end
      )

    Application.put_env(:serviceradar_web_ng, :srql_module, FakeSRQL)
    Application.put_env(:serviceradar_web_ng, :northbound_catalog_module, FakeCatalog)
    Application.put_env(:serviceradar_web_ng, :northbound_invocation_service_module, RecordingInvocationService)
    Application.put_env(:serviceradar_web_ng, :dashboard_live_test_pid, self())

    user = AccountsFixtures.user_fixture()
    scope = Scope.for_user(user, permissions: RBAC.permissions_for_user(user))

    on_exit(fn ->
      Application.delete_env(:serviceradar_web_ng, :dashboard_live_test_pid)
      Application.delete_env(:serviceradar_web_ng, :dashboard_frame_test_pid)
      Application.delete_env(:serviceradar_web_ng, :dashboard_frame_flaky_mode)

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:serviceradar_web_ng, key)
        {key, value} -> Application.put_env(:serviceradar_web_ng, key, value)
      end)
    end)

    {:ok, user: user, scope: scope}
  end

  describe "actions:invoke" do
    test "is rejected when the package does not declare actions.invoke" do
      socket = join!(:operator, ["srql.execute"])

      ref = push(socket, "actions:invoke", invoke_payload())

      assert_reply ref, :error, %{"reason" => "dashboard capability is not approved: actions.invoke"}
      refute_received {:invocation_requested, _attrs, _opts}
    end

    test "is rejected for a viewer without northbound.actions.launch" do
      socket = join!(:viewer, ["srql.execute", "actions.invoke"])

      ref = push(socket, "actions:invoke", invoke_payload())

      assert_reply ref, :error, %{"reason" => "You are not authorized to launch actions."}
      refute_received {:invocation_requested, _attrs, _opts}
    end

    test "dispatches with the viewer as actor and pushes progress to a terminal state" do
      {socket, user} = join_with_user!(:operator, ["srql.execute", "actions.invoke"])

      ref = push(socket, "actions:invoke", invoke_payload())

      # Creating and dispatching the invocation makes several database round trips.
      assert_reply ref, :ok, %{"invocation_id" => invocation_id, "state" => "dispatching"}, 8_000
      assert_received {:invocation_requested, attrs, opts}
      assert Keyword.fetch!(opts, :actor).id == user.id
      assert attrs.source == :user
      assert attrs.targets == [%{kind: "device", device_uid: "sr:device:plc-07"}]
      assert attrs.metadata["ui_surface"] == "dashboard_package"

      system = AshTestHelpers.system_actor()

      ActionInvocation
      |> Ash.get!(invocation_id, actor: system)
      |> Ash.Changeset.for_update(:record_running, %{}, actor: system)
      |> Ash.update!()
      |> Ash.Changeset.for_update(:record_succeeded, %{result_summary: %{"ok" => true}}, actor: system)
      |> Ash.update!()

      assert_push "actions:progress",
                  %{"invocation_id" => ^invocation_id, "state" => "succeeded"},
                  8_000
    end
  end

  # The test process stands in for the dashboard LiveView: the stream token names
  # it as the confirmation host, so it receives the confirmation request and
  # answers it the way the LiveView does.
  describe "actions:invoke with requires_confirmation" do
    test "holds the invocation for the host and dispatches nothing" do
      {socket, user} = join_with_user!(:operator, ["srql.execute", "actions.invoke"], confirmation_host: self())

      ref = push(socket, "actions:invoke", confirm_payload())

      assert_reply ref, :ok, %{"state" => "confirmation_required", "confirmation_id" => id, "expires_in_ms" => ttl}
      assert ttl == ActionConfirmations.ttl_ms()
      assert_receive {:dashboard_action_confirmation_request, request}
      assert request.id == id
      assert request.channel_pid == socket.channel_pid
      assert request.user_id == to_string(user.id)
      assert request.label == "Reset controller"
      assert request.safety_classification == "destructive"
      assert request.targets == [%{device_uid: "sr:device:plc-07", interface_uid: nil}]
      refute_receive {:invocation_requested, _attrs, _opts}, 300
    end

    test "dispatches exactly once after the host confirms" do
      {socket, user} = join_with_user!(:operator, ["srql.execute", "actions.invoke"], confirmation_host: self())
      request = request_confirmation!(socket)
      reply = {:dashboard_action_confirmation_reply, request.id, :confirmed, host_reply(user, request)}

      send(socket.channel_pid, reply)
      send(socket.channel_pid, reply)

      assert_push "actions:confirmation",
                  %{"state" => "confirmed", "invocation" => %{"invocation_id" => _id}},
                  8_000

      assert_received {:invocation_requested, attrs, opts}
      assert Keyword.fetch!(opts, :actor).id == user.id
      assert attrs.targets == [%{kind: "device", device_uid: "sr:device:plc-07"}]
      assert attrs.input_values == %{"reason" => "scheduled"}
      assert attrs.metadata["confirmation"] == %{"method" => "host_dialog", "confirmation_id" => request.id}

      refute_receive {:invocation_requested, _attrs, _opts}, 500
    end

    test "rejects a confirmation bound to a different target set and burns it" do
      {socket, user} = join_with_user!(:operator, ["srql.execute", "actions.invoke"], confirmation_host: self())
      request = request_confirmation!(socket)

      other_binding =
        ActionConfirmations.binding(
          user.id,
          @confirm_action_id,
          "device",
          [%{kind: "device", device_uid: "sr:device:plc-99"}],
          %{"reason" => "scheduled"}
        )

      send(
        socket.channel_pid,
        {:dashboard_action_confirmation_reply, request.id, :confirmed,
         %{user_id: to_string(user.id), binding: other_binding}}
      )

      assert_push "actions:confirmation", %{"state" => "rejected", "reason" => reason}
      assert reason == "The confirmation does not match this action request."

      # The mismatch consumed the entry: the genuine answer can no longer release it.
      send(socket.channel_pid, {:dashboard_action_confirmation_reply, request.id, :confirmed, host_reply(user, request)})
      refute_push "actions:confirmation", _payload, 300
      refute_received {:invocation_requested, _attrs, _opts}
    end

    test "rejects a confirmation answered after it expired" do
      {socket, user} = join_with_user!(:operator, ["srql.execute", "actions.invoke"], confirmation_host: self())
      request = request_confirmation!(socket)

      # Monotonic time can be negative, so "in the past" is relative to now.
      expired_at = System.monotonic_time(:millisecond) - 1

      :sys.replace_state(socket.channel_pid, fn channel_socket ->
        update_in(channel_socket.assigns.action_confirmations[request.id], &Map.put(&1, :expires_at_ms, expired_at))
      end)

      send(socket.channel_pid, {:dashboard_action_confirmation_reply, request.id, :confirmed, host_reply(user, request)})

      assert_push "actions:confirmation", %{"state" => "rejected", "reason" => reason}
      assert reason == "The confirmation expired before it was answered."
      assert_receive {:dashboard_action_confirmation_closed, closed_id}
      assert closed_id == request.id
      refute_received {:invocation_requested, _attrs, _opts}
    end

    test "expires an unanswered confirmation, closes the host dialog and refuses a late answer" do
      {socket, user} = join_with_user!(:operator, ["srql.execute", "actions.invoke"], confirmation_host: self())
      request = request_confirmation!(socket)

      send(socket.channel_pid, {:dashboard_action_confirmation_expired, request.id})

      assert_push "actions:confirmation", %{"state" => "expired"}
      assert_receive {:dashboard_action_confirmation_closed, closed_id}
      assert closed_id == request.id

      send(socket.channel_pid, {:dashboard_action_confirmation_reply, request.id, :confirmed, host_reply(user, request)})
      refute_push "actions:confirmation", _payload, 300
      refute_received {:invocation_requested, _attrs, _opts}
    end

    test "a declined confirmation dispatches nothing" do
      {socket, user} = join_with_user!(:operator, ["srql.execute", "actions.invoke"], confirmation_host: self())
      request = request_confirmation!(socket)

      send(socket.channel_pid, {:dashboard_action_confirmation_reply, request.id, :declined, host_reply(user, request)})

      assert_push "actions:confirmation", %{"state" => "declined"}
      refute_receive {:invocation_requested, _attrs, _opts}, 300
    end

    test "is refused when no host can render the confirmation" do
      socket = join!(:operator, ["srql.execute", "actions.invoke"])

      ref = push(socket, "actions:invoke", confirm_payload())

      assert_reply ref, :error, %{"reason" => "This action requires confirmation in the ServiceRadar host."}
      refute_receive {:invocation_requested, _attrs, _opts}, 300
    end

    test "leaves actions without requires_confirmation dispatching immediately" do
      socket = join!(:operator, ["srql.execute", "actions.invoke"], confirmation_host: self())

      ref = push(socket, "actions:invoke", invoke_payload())

      assert_reply ref, :ok, %{"invocation_id" => _id, "state" => "dispatching"}, 8_000
      assert_received {:invocation_requested, _attrs, _opts}
      refute_received {:dashboard_action_confirmation_request, _request}
    end
  end

  describe "events:subscribe" do
    test "is rejected when the package does not declare events.subscribe" do
      socket = join!(:viewer, ["srql.execute"])

      ref = push(socket, "events:subscribe", %{"id" => "s1", "filter" => %{}})

      assert_reply ref, :error, %{"reason" => "dashboard capability is not approved: events.subscribe"}
    end

    test "pushes matching persisted events and withholds non-matching ones" do
      socket = join!(:viewer, ["srql.execute", "events.subscribe"])
      subscribe!(socket, %{"log_provider" => "plugin:showcase-ot"})

      matching = persisted_event!("plugin:showcase-ot")
      :ok = EventsPubSub.broadcast_event_rows([matching, persisted_event!("plugin:other")])

      assert_push "events:batch", %{"subscription_id" => "s1", "events" => [%{"id" => matching_id}]}
      assert matching_id == Ecto.UUID.load!(matching.id)

      :ok = EventsPubSub.broadcast_event_rows([persisted_event!("plugin:other")])
      refute_push "events:batch", _payload, 300
    end

    test "withholds events the viewer's own read of ocsf_events does not return" do
      # helpdesk is outside the OcsfEvent read policy, which is a filter: the
      # subscription is accepted, and every row is filtered out at delivery.
      socket = join!(:helpdesk, ["srql.execute", "events.subscribe"])
      subscribe!(socket, %{"log_provider" => "plugin:showcase-ot"})

      :ok = EventsPubSub.broadcast_event_rows([persisted_event!("plugin:showcase-ot")])

      refute_push "events:batch", _payload, 500
    end

    test "drops subscriptions once the viewer is deactivated" do
      {socket, user} = join_with_user!(:viewer, ["srql.execute", "events.subscribe"])
      subscribe!(socket, %{"log_provider" => "plugin:showcase-ot"})

      {:ok, _user} = Users.deactivate(user, actor: AshTestHelpers.system_actor(), authorize?: false)

      # Delivery refreshes the viewer at most every 30 s; expire the last check
      # instead of sleeping through the interval.
      :sys.replace_state(socket.channel_pid, fn channel_socket ->
        put_in(channel_socket.assigns.events_authorized_at, nil)
      end)

      :ok = EventsPubSub.broadcast_event_rows([persisted_event!("plugin:showcase-ot")])

      assert_push "events:error", %{"reason" => "You are not authorized to read events."}
      refute_push "events:batch", _payload, 300

      :ok = EventsPubSub.broadcast_event_rows([persisted_event!("plugin:showcase-ot")])
      refute_push "events:error", _payload, 300
    end
  end

  describe "frame streaming and cursor paging" do
    test "joins with a signed stream token and pushes JSON row frames", %{user: user, scope: scope} do
      route_slug = "test-dashboard-#{System.unique_integer([:positive])}"
      data_frames = [%{"id" => "rows", "query" => "in:test_rows", "encoding" => "json_rows", "limit" => 1}]
      create_stream_dashboard_instance!(route_slug, data_frames, scope)
      token = DashboardFrameChannel.stream_token(route_slug, data_frames, user.id)

      assert {:ok, %{"refresh_interval_ms" => 15_000}, _socket} =
               UserSocket
               |> socket("user-id", %{current_user: user, current_scope: scope})
               |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => token})

      assert_push "frames:replace", %{
        "frames" => [
          %{
            "id" => "rows",
            "status" => "ok",
            "encoding" => "json_rows",
            "results" => [%{"id" => "row-1", "value" => 7}]
          }
        ],
        "pending_binary_frame_ids" => []
      }

      refute_push "frame:binary", _payload, 100
    end

    test "pages one frame through the existing SRQL cursor without replacing the query", %{user: user, scope: scope} do
      route_slug = "test-dashboard-#{System.unique_integer([:positive])}"
      data_frames = [%{"id" => "rows", "query" => "in:test_paged_rows", "encoding" => "json_rows", "limit" => 1}]
      create_stream_dashboard_instance!(route_slug, data_frames, scope)
      token = DashboardFrameChannel.stream_token(route_slug, data_frames, user.id)

      assert {:ok, _reply, socket} =
               UserSocket
               |> socket("user-id", %{current_user: user, current_scope: scope})
               |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => token})

      assert_push "frames:replace", %{"frames" => [%{"id" => "rows", "results" => [%{"id" => "row-1"}]}]}

      ref = push(socket, "frames:page", %{"frame_id" => "rows", "cursor" => "page-two"})
      assert_reply ref, :ok, %{}

      assert_push "frames:replace", %{
        "frames" => [
          %{
            "id" => "rows",
            "query" => "in:test_paged_rows",
            "results" => [%{"id" => "row-2"}]
          }
        ]
      }
    end

    test "streams Arrow IPC frame payloads as channel binary frames", %{user: user, scope: scope} do
      route_slug = "test-dashboard-#{System.unique_integer([:positive])}"
      data_frames = [%{"id" => "arrow", "query" => "in:test_arrow", "encoding" => "arrow_ipc", "limit" => 1}]
      create_stream_dashboard_instance!(route_slug, data_frames, scope)
      token = DashboardFrameChannel.stream_token(route_slug, data_frames, user.id)

      assert {:ok, _reply, _socket} =
               UserSocket
               |> socket("user-id", %{current_user: user, current_scope: scope})
               |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => token})

      assert_push "frames:replace", %{
        "frames" => [
          %{
            "id" => "arrow",
            "status" => "ok",
            "encoding" => "arrow_ipc",
            "results" => [],
            "schema" => %{"columns" => ["id"]}
          }
        ],
        "pending_binary_frame_ids" => ["arrow"]
      }

      assert_push "frame:binary", %{
        frame_id: "arrow",
        payload: <<_magic::binary-size(4), _header_length::unsigned-big-integer-size(32), _rest::binary>>
      }
    end

    test "recovers from refresh failure and resumes streaming on subsequent ticks", %{user: user, scope: scope} do
      route_slug = "test-dashboard-#{System.unique_integer([:positive])}"
      data_frames = [%{"id" => "flaky", "query" => "in:test_flaky_rows", "encoding" => "json_rows", "limit" => 1}]
      create_stream_dashboard_instance!(route_slug, data_frames, scope)
      token = DashboardFrameChannel.stream_token(route_slug, data_frames, user.id)

      Application.put_env(:serviceradar_web_ng, :dashboard_frame_flaky_mode, :error)

      assert {:ok, _reply, socket} =
               UserSocket
               |> socket("user-id", %{current_user: user, current_scope: scope})
               |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => token})

      assert_push "frames:error", %{"reason" => "frame_stream_unavailable"}

      Application.put_env(:serviceradar_web_ng, :dashboard_frame_flaky_mode, :ok)
      send(socket.channel_pid, :dashboard_frame_tick)

      assert_push "frames:replace", %{
        "frames" => [
          %{
            "id" => "flaky",
            "status" => "ok",
            "encoding" => "json_rows",
            "results" => [%{"id" => "row-good", "value" => 13}]
          }
        ]
      }
    end

    test "pushes deferred frames after the initial frames are acknowledged", %{user: user, scope: scope} do
      route_slug = "test-dashboard-#{System.unique_integer([:positive])}"

      data_frames = [
        %{"id" => "initial", "query" => "in:test_rows", "encoding" => "json_rows", "defer" => false},
        %{"id" => "deferred", "query" => "in:test_optional_rows", "encoding" => "json_rows", "defer" => true}
      ]

      create_stream_dashboard_instance!(route_slug, data_frames, scope)
      token = DashboardFrameChannel.stream_token(route_slug, data_frames, user.id)

      assert {:ok, _reply, _socket} =
               UserSocket
               |> socket("user-id", %{current_user: user, current_scope: scope})
               |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => token})

      assert_push "frames:replace", %{"frames" => [%{"id" => "initial"}]}
      refute_push "frames:replace", %{"frames" => [%{"id" => "deferred"}]}, 100

      assert_push "frames:replace", %{"frames" => [%{"id" => "deferred"}]}, 1_000
    end

    test "cached frames return immediately on join", %{user: user, scope: scope} do
      route_slug = "test-dashboard-#{System.unique_integer([:positive])}"
      data_frames = [%{"id" => "rows", "query" => "in:test_rows", "encoding" => "json_rows"}]
      create_stream_dashboard_instance!(route_slug, data_frames, scope)

      DashboardFrameChannel.put_cached_frames(route_slug, [
        %{"id" => "rows", "results" => [%{"id" => "cached-1"}], "status" => "ok"}
      ])

      token = DashboardFrameChannel.stream_token(route_slug, data_frames, user.id)

      assert {:ok, %{"refresh_interval_ms" => 15_000}, _socket} =
               UserSocket
               |> socket("user-id", %{current_user: user, current_scope: scope})
               |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => token})

      assert_push "frames:replace", %{"frames" => [%{"id" => "rows", "results" => [%{"id" => "cached-1"}]}]}
    end

    test "executes query outside the channel process and handles timeouts", %{user: user, scope: scope} do
      Application.put_env(:serviceradar_web_ng, :dashboard_frame_test_pid, self())

      route_slug = "test-dashboard-#{System.unique_integer([:positive])}"
      data_frames = [%{"id" => "slow", "query" => "in:test_slow_rows", "encoding" => "json_rows", "timeout_ms" => 50}]
      create_stream_dashboard_instance!(route_slug, data_frames, scope)
      token = DashboardFrameChannel.stream_token(route_slug, data_frames, user.id)

      assert {:ok, _reply, socket} =
               UserSocket
               |> socket("user-id", %{current_user: user, current_scope: scope})
               |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => token})

      assert_receive {:srql_query_started, "in:test_slow_rows", query_runner_pid}
      assert query_runner_pid != socket.channel_pid

      assert_push "frames:replace", %{
        "frames" => [
          %{
            "id" => "slow",
            "status" => "error",
            "error" => "query_timeout",
            "results" => []
          }
        ]
      }
    end

    test "a tick over unchanged data pushes no frame replacement", %{user: user, scope: scope} do
      Application.put_env(:serviceradar_web_ng, :dashboard_frame_test_pid, self())

      route_slug = "test-dashboard-#{System.unique_integer([:positive])}"
      data_frames = [%{"id" => "required", "query" => "in:test_rows", "encoding" => "json_rows", "limit" => 1}]

      create_stream_dashboard_instance!(route_slug, data_frames, scope)
      token = DashboardFrameChannel.stream_token(route_slug, data_frames, user.id, [])

      assert {:ok, _reply, socket} =
               UserSocket
               |> socket("user-id", %{current_user: user, current_scope: scope})
               |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => token})

      assert_push "frames:replace", %{"frames" => [%{"id" => "required", "status" => "ok"}]}
      assert_receive {:srql_query, "in:test_rows"}

      # Tick again over identical data.
      send(socket.channel_pid, :dashboard_frame_tick)
      assert_receive {:srql_query, "in:test_rows"}

      # The data did not change, so no frame may be sent...
      refute_push "frames:replace", %{}, 200
      refute_push "frame:binary", %{}, 50

      # ...but the client is still told we looked, so it can render data age.
      assert_push "frames:heartbeat", %{"checked_at" => checked_at}
      assert is_binary(checked_at)
    end

    test "forcing a refresh does not discard the paging position", %{user: user, scope: scope} do
      Application.put_env(:serviceradar_web_ng, :dashboard_frame_test_pid, self())

      route_slug = "test-dashboard-#{System.unique_integer([:positive])}"
      data_frames = [%{"id" => "required", "query" => "in:test_rows", "encoding" => "json_rows", "limit" => 1}]

      create_stream_dashboard_instance!(route_slug, data_frames, scope)
      token = DashboardFrameChannel.stream_token(route_slug, data_frames, user.id, [])

      assert {:ok, _reply, socket} =
               UserSocket
               |> socket("user-id", %{current_user: user, current_scope: scope})
               |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => token})

      assert_push "frames:replace", %{"frames" => [%{"id" => "required"}]}
      assert_receive {:srql_query, "in:test_rows"}

      ref = push(socket, "frames:page", %{"frame_id" => "required", "cursor" => "cursor-1"})
      assert_reply ref, :ok, %{}
      assert_receive {:srql_query, "in:test_rows"}
      wait_until_settled(socket.channel_pid)

      assert :sys.get_state(socket.channel_pid).assigns.frame_cursors == %{"required" => "cursor-1"}

      ref = push(socket, "frames:refresh", %{})
      assert_reply ref, :ok, %{}

      assert :sys.get_state(socket.channel_pid).assigns.frame_cursors == %{"required" => "cursor-1"},
             "a forced refresh must not move the user's page"
    end

    test "paging while a refresh is in flight is refused rather than silently dropped",
         %{user: user, scope: scope} do
      Application.put_env(:serviceradar_web_ng, :dashboard_frame_test_pid, self())

      route_slug = "test-dashboard-#{System.unique_integer([:positive])}"
      data_frames = [%{"id" => "required", "query" => "in:test_rows", "encoding" => "json_rows", "limit" => 1}]

      create_stream_dashboard_instance!(route_slug, data_frames, scope)
      token = DashboardFrameChannel.stream_token(route_slug, data_frames, user.id, [])

      assert {:ok, _reply, socket} =
               UserSocket
               |> socket("user-id", %{current_user: user, current_scope: scope})
               |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => token})

      assert_push "frames:replace", %{"frames" => [%{"id" => "required"}]}
      assert_receive {:srql_query, "in:test_rows"}

      # Pin a refresh task open, then page against it.
      :sys.replace_state(socket.channel_pid, fn state ->
        %{state | assigns: Map.put(state.assigns, :refresh_task_ref, make_ref())}
      end)

      ref = push(socket, "frames:page", %{"frame_id" => "required", "cursor" => "cursor-1"})
      assert_reply ref, :error, %{reason: "refresh_in_progress"}

      ref = push(socket, "frames:refresh", %{})
      assert_reply ref, :error, %{reason: "refresh_in_progress"}
    end
  end

  describe "stream token verification and access control" do
    test "rejects an invalid stream token on join", %{user: user, scope: scope} do
      route_slug = "test-dashboard-#{System.unique_integer([:positive])}"
      create_stream_dashboard_instance!(route_slug, [], scope)

      assert {:error, %{reason: "invalid_token"}} =
               UserSocket
               |> socket("user-id", %{current_user: user, current_scope: scope})
               |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => "bad-token"})
    end

    test "rejects join when token route slug does not match topic", %{user: user, scope: scope} do
      route_slug = "test-dashboard-#{System.unique_integer([:positive])}"
      token = DashboardFrameChannel.stream_token("other-route", [], user.id)
      create_stream_dashboard_instance!(route_slug, [], scope)

      assert {:error, %{reason: "invalid_stream"}} =
               UserSocket
               |> socket("user-id", %{current_user: user, current_scope: scope})
               |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => token})
    end

    test "rejects join when missing token", %{user: user, scope: scope} do
      route_slug = "test-dashboard-#{System.unique_integer([:positive])}"
      create_stream_dashboard_instance!(route_slug, [], scope)

      assert {:error, %{reason: "missing_stream_token"}} =
               UserSocket
               |> socket("user-id", %{current_user: user, current_scope: scope})
               |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{})
    end

    test "rejects a stream token minted for another user", %{user: user, scope: scope} do
      other = AccountsFixtures.user_fixture()
      other_scope = Scope.for_user(other, permissions: RBAC.permissions_for_user(other))
      route_slug = "test-dashboard-#{System.unique_integer([:positive])}"
      data_frames = [%{"id" => "rows", "query" => "in:test_rows", "encoding" => "json_rows"}]
      create_stream_dashboard_instance!(route_slug, data_frames, scope)
      token = DashboardFrameChannel.stream_token(route_slug, data_frames, user.id)

      assert {:error, %{reason: "unauthorized"}} =
               UserSocket
               |> socket("other-user", %{current_user: other, current_scope: other_scope})
               |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => token})
    end

    test "rejects a still-valid token after the view grant is revoked", %{scope: owner_scope} do
      viewer = AccountsFixtures.user_fixture(%{role: :viewer})
      viewer_scope = Scope.for_user(viewer, permissions: RBAC.permissions_for_user(viewer))
      route_slug = "test-dashboard-#{System.unique_integer([:positive])}"
      data_frames = [%{"id" => "rows", "query" => "in:test_rows", "encoding" => "json_rows"}]

      instance =
        create_stream_dashboard_instance!(route_slug, data_frames, owner_scope, %{
          visibility: :shared,
          owner_id: owner_scope.user.id
        })

      {:ok, grant} =
        DashboardInstanceAccessGrant
        |> Ash.Changeset.for_create(:create, %{
          dashboard_instance_id: instance.id,
          subject_user_id: viewer.id,
          access: :view,
          granted_by_id: owner_scope.user.id
        })
        |> Ash.create(actor: SystemActor.system(:test))

      token = DashboardFrameChannel.stream_token(route_slug, data_frames, viewer.id)

      assert {:ok, _reply, _socket} =
               UserSocket
               |> socket("viewer-id", %{current_user: viewer, current_scope: viewer_scope})
               |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => token})

      :ok = Ash.destroy(grant, actor: SystemActor.system(:test))

      assert {:error, %{reason: "dashboard_unavailable"}} =
               UserSocket
               |> socket("viewer-id", %{current_user: viewer, current_scope: viewer_scope})
               |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => token})
    end
  end

  defp join!(role, capabilities, opts \\ []) do
    {socket, _user} = join_with_user!(role, capabilities, opts)
    socket
  end

  defp join_with_user!(role, capabilities, opts \\ []) do
    user = AccountsFixtures.user_fixture(%{role: role})
    scope = Scope.for_user(user, permissions: RBAC.permissions_for_user(user))
    route_slug = "live-dashboard-#{System.unique_integer([:positive])}"
    create_dashboard_instance!(route_slug, capabilities)

    token = DashboardFrameChannel.stream_token(route_slug, @data_frames, user.id, [], capabilities, opts)

    {:ok, _reply, socket} =
      UserSocket
      |> socket("user-id", %{current_user: user, current_scope: scope})
      |> subscribe_and_join(DashboardFrameChannel, "dashboards:#{route_slug}", %{"token" => token})

    {socket, user}
  end

  defp subscribe!(socket, filter) do
    ref = push(socket, "events:subscribe", %{"id" => "s1", "filter" => filter})
    assert_reply ref, :ok, %{"subscription_id" => "s1"}
  end

  defp request_confirmation!(socket) do
    ref = push(socket, "actions:invoke", confirm_payload())
    assert_reply ref, :ok, %{"state" => "confirmation_required", "confirmation_id" => id}
    assert_receive {:dashboard_action_confirmation_request, %{id: ^id} = request}
    request
  end

  # What the LiveView sends back: the operator's id and the binding the dialog showed.
  defp host_reply(user, request), do: %{user_id: to_string(user.id), binding: request.binding}

  defp confirm_payload do
    %{
      "action_id" => @confirm_action_id,
      "scope" => "device",
      "targets" => [%{"device_uid" => "sr:device:plc-07"}],
      "input" => %{"reason" => "scheduled"}
    }
  end

  defp invoke_payload do
    %{"action_id" => @action_id, "scope" => "device", "targets" => [%{"device_uid" => "sr:device:plc-07"}]}
  end

  # Writes the row the way EventWriter does (raw uuid, jsonb maps) so delivery
  # can read it back through the viewer's own policy.
  defp persisted_event!(log_provider) do
    row = %{
      id: Ecto.UUID.dump!(Ecto.UUID.generate()),
      time: DateTime.utc_now(),
      class_uid: 1008,
      category_uid: 1,
      type_uid: 100_801,
      activity_id: 1,
      severity_id: 4,
      log_provider: log_provider,
      device: %{"uid" => "sr:device:plc-07"},
      metadata: %{"fault_kind" => "jam"}
    }

    {1, _} = ServiceRadar.Repo.insert_all("ocsf_events", [row], prefix: "platform")
    row
  end

  defp create_dashboard_instance!(route_slug, capabilities) do
    system = AshTestHelpers.system_actor()
    dashboard_id = "com.test.live.#{System.unique_integer([:positive])}"

    manifest = %{
      "id" => dashboard_id,
      "name" => "Live Dashboard",
      "version" => "0.1.0",
      "renderer" => %{
        "kind" => "browser_wasm",
        "interface_version" => "dashboard-wasm-v1",
        "artifact" => "dashboard.wasm",
        "sha256" => String.duplicate("a", 64)
      },
      "data_frames" => @data_frames,
      "capabilities" => capabilities,
      "settings_schema" => %{}
    }

    package =
      DashboardPackage
      |> Ash.Changeset.for_create(:create, %{
        dashboard_id: dashboard_id,
        name: manifest["name"],
        version: manifest["version"],
        manifest: manifest,
        renderer: manifest["renderer"],
        data_frames: @data_frames,
        capabilities: capabilities,
        settings_schema: %{},
        wasm_object_key: "dashboards/test/dashboard.wasm",
        content_hash: String.duplicate("a", 64),
        verification_status: "verified"
      })
      |> Ash.create!(actor: system)

    DashboardInstance
    |> Ash.Changeset.for_create(:create, %{
      dashboard_package_id: package.id,
      name: "Live Dashboard",
      route_slug: route_slug,
      placement: :custom,
      enabled: true,
      settings: %{},
      metadata: %{}
    })
    |> Ash.create!(actor: system)
  end

  defp create_stream_dashboard_instance!(route_slug, data_frames, scope, extra \\ %{}) do
    package =
      DashboardPackage
      |> Ash.Changeset.for_create(:create, package_attrs(data_frames))
      |> Ash.create!(scope: scope)

    DashboardInstance
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          dashboard_package_id: package.id,
          name: "Test Dashboard",
          route_slug: route_slug,
          placement: :custom,
          enabled: true,
          settings: %{},
          metadata: %{}
        },
        extra
      )
    )
    |> Ash.create!(scope: scope)
  end

  defp package_attrs(data_frames) do
    manifest = %{
      "id" => "com.test.dashboard.#{System.unique_integer([:positive])}",
      "name" => "Test Dashboard",
      "version" => "0.1.0",
      "renderer" => %{
        "kind" => "browser_wasm",
        "interface_version" => "dashboard-wasm-v1",
        "artifact" => "dashboard.wasm",
        "sha256" => String.duplicate("a", 64)
      },
      "data_frames" => data_frames,
      "capabilities" => ["srql.execute"],
      "settings_schema" => %{}
    }

    %{
      dashboard_id: manifest["id"],
      name: manifest["name"],
      version: manifest["version"],
      manifest: manifest,
      renderer: manifest["renderer"],
      data_frames: data_frames,
      capabilities: manifest["capabilities"],
      settings_schema: manifest["settings_schema"],
      wasm_object_key: "dashboards/test/dashboard.wasm",
      content_hash: String.duplicate("a", 64),
      verification_status: "verified"
    }
  end

  defp wait_until_settled(channel_pid, attempts \\ 20) do
    if :sys.get_state(channel_pid).assigns[:refresh_task_ref] != nil do
      if attempts <= 0, do: raise("channel task did not settle")
      Process.sleep(5)
      wait_until_settled(channel_pid, attempts - 1)
    end
  end
end
