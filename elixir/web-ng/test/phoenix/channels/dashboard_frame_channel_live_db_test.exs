defmodule ServiceRadarWebNGWeb.DashboardFrameChannelLiveDbTest do
  @moduledoc """
  Database-backed coverage for the dashboard channel's plugin-action and
  live-event paths: capability and permission rejection, dispatch with the
  viewer as actor, progress pushed to a terminal state, event matching, and
  subscriptions dropped when event access is revoked.
  """

  use ServiceRadarWebNG.DataCase, async: false

  import Phoenix.ChannelTest

  alias ServiceRadar.Automation.Northbound.ActionInvocation
  alias ServiceRadar.Dashboards.DashboardInstance
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
    def query(_query, _opts), do: {:ok, %{"results" => [], "pagination" => %{"limit" => 1}}}
  end

  defmodule FakeCatalog do
    @moduledoc false
    def eligible_device_actions(_scope) do
      [
        %{
          id: "northbound:showcase-fault",
          descriptor_id: nil,
          label: "Inject fault",
          description: nil,
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
      Map.new([:srql_module, :northbound_catalog_module, :northbound_invocation_service_module], fn key ->
        {key, Application.get_env(:serviceradar_web_ng, key)}
      end)

    Application.put_env(:serviceradar_web_ng, :srql_module, FakeSRQL)
    Application.put_env(:serviceradar_web_ng, :northbound_catalog_module, FakeCatalog)
    Application.put_env(:serviceradar_web_ng, :northbound_invocation_service_module, RecordingInvocationService)
    Application.put_env(:serviceradar_web_ng, :dashboard_live_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:serviceradar_web_ng, :dashboard_live_test_pid)

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:serviceradar_web_ng, key)
        {key, value} -> Application.put_env(:serviceradar_web_ng, key, value)
      end)
    end)

    :ok
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
end
