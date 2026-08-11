defmodule ServiceRadarWebNGWeb.NotificationFirehoseChannelTest do
  @moduledoc """
  The firehose subscriber's authorization and replay contract (tasks 4.4.2,
  4.4.2b, and 4.4.3).

  These run without a database and without a socket: `join/3` refuses an
  unauthorized scope before it touches JetStream, and `filter_envelope/2` is a pure
  function over a map. Asserting either one only through a live socket would mean
  asserting it in a tier that needs infrastructure to run, which is how a
  security assertion quietly stops being run at all.
  """

  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.NotificationFirehoseChannel, as: Channel

  # web-ng's Bazel tier runs `ExUnit.configure(exclude: [:test], include: [:db_free])`,
  # so an untagged file runs ZERO tests in CI while reporting success. These need no
  # database - that is the point of the tag, not a workaround for one.
  @moduletag :db_free

  @firehose "notifications:stream"

  @envelope %{
    "schema" => "serviceradar.notification_envelope.v1",
    "alert_id" => "alert-1",
    "delivery_id" => "delivery-1",
    "channel_id" => "channel-1",
    "payload" => %{"subject" => "Disk pressure", "body" => "node-3 at 94%"}
  }

  defmodule CurrentAuthorization do
    @moduledoc false
    def authorize_current(%Scope{} = scope, required_permissions) do
      current_permissions =
        case scope.user do
          %{current_permissions: %MapSet{} = permissions} -> permissions
          _user -> scope.permissions || MapSet.new()
        end

      if Enum.all?(required_permissions, &MapSet.member?(current_permissions, &1)) do
        {:ok, %{scope | permissions: current_permissions}}
      else
        {:error, :permission_revoked}
      end
    end
  end

  defmodule ReplayStub do
    @moduledoc false
    def start(topic, payload, scope, channel_pid, opts) do
      send(opts[:test_pid], {:join_step, :durable_started})
      send(opts[:test_pid], {:replay_started, topic, payload, scope, channel_pid})

      case {payload["client_id"], payload["cursor"]} do
        {nil, _cursor} ->
          {:error, :client_id_required}

        {_client_id, "behind-retention"} ->
          {:error, {:cursor_gap, "signed-earliest-cursor"}}

        {client_id, _cursor} ->
          {:ok,
           %{
             client_id: client_id,
             consumer_name: "server-controlled",
             consumer_pid: channel_pid,
             initial_cursor: "signed-baseline-cursor",
             stream_name: "NOTIFICATIONS",
             subject: "notifications.stream"
           }}
      end
    end

    def cursor_token(_replay, next_sequence), do: {:ok, "signed-cursor-#{next_sequence}"}

    def stop(_replay), do: :ok
  end

  defp scope(permissions, current_permissions) do
    Scope.for_user(
      %{
        id: Ecto.UUID.generate(),
        email: "operator@example.com",
        current_permissions: current_permissions
      },
      permissions: MapSet.new(permissions)
    )
  end

  defp socket_with(permissions, current_permissions \\ nil) do
    %Phoenix.Socket{
      assigns: %{
        current_scope: scope(permissions, current_permissions),
        authorization_module: CurrentAuthorization
      }
    }
  end

  defp socket_with_replay(permissions, current_permissions) do
    socket = socket_with(permissions, current_permissions)

    %{
      socket
      | assigns:
          Map.merge(socket.assigns, %{
            firehose_replay_module: ReplayStub,
            firehose_replay_opts: [test_pid: self()]
          })
    }
  end

  defp socket_with_push(permissions, current_permissions) do
    test_pid = self()
    socket = socket_with(permissions, current_permissions)

    %{
      socket
      | assigns:
          Map.merge(socket.assigns, %{
            firehose_push: fn _socket, event, envelope ->
              send(test_pid, {:pushed, event, envelope})
              :ok
            end,
            firehose_replay: %{client_id: "browser-profile-1"},
            firehose_replay_module: ReplayStub
          })
    }
  end

  describe "join/3 authorization" do
    test "refuses a scope without notifications.stream.subscribe" do
      assert {:error, %{reason: "unauthorized"}} =
               Channel.join(@firehose, %{}, socket_with(["notifications.channels.view"]))
    end

    test "refuses a scope with no permissions at all" do
      assert {:error, %{reason: "unauthorized"}} = Channel.join(@firehose, %{}, socket_with([]))
    end

    test "refuses a stale cached subscribe permission after revocation" do
      assert {:error, %{reason: "unauthorized"}} =
               Channel.join(
                 @firehose,
                 %{},
                 socket_with([Channel.subscribe_permission()], MapSet.new())
               )
    end

    test "refuses a suffixed topic to a scope without the subscribe permission" do
      # A suffix narrows which envelopes a subscriber receives. It is not a
      # second, weaker way in.
      assert {:error, %{reason: "unauthorized"}} =
               Channel.join(@firehose <> ":ops", %{}, socket_with(["notifications.routes.view"]))
    end

    test "refuses a topic outside the notification namespace" do
      assert {:error, %{reason: "unknown_topic"}} =
               Channel.join(
                 "topology:god_view",
                 %{},
                 socket_with([Channel.subscribe_permission()])
               )
    end

    test "refuses a suffix that the transport would not have saved" do
      # Mirrors the transport's suffix charset, so a crafted topic cannot reach a
      # namespace an operator was never granted.
      for hostile <- ["Ops", "ops!", "-ops", String.duplicate("o", 65), ""] do
        assert {:error, %{reason: "unknown_topic"}} =
                 Channel.join(
                   @firehose <> ":" <> hostile,
                   %{},
                   socket_with([Channel.subscribe_permission()])
                 ),
               "expected #{inspect(hostile)} to be refused as a topic suffix"
      end
    end

    test "starts durable replay for an authorized client before accepting the join" do
      permissions = [Channel.subscribe_permission(), Channel.payload_permission()]
      socket = socket_with_replay(permissions, MapSet.new(permissions))

      assert {:ok,
              %{
                client_id: "browser-profile-1",
                cursor: "signed-baseline-cursor",
                durable: true
              }, joined_socket} =
               Channel.join(@firehose, %{"client_id" => "browser-profile-1"}, socket)

      assert joined_socket.assigns.firehose_replay.client_id == "browser-profile-1"
      assert_receive {:join_step, :durable_started}

      assert_received {:replay_started, @firehose, %{"client_id" => "browser-profile-1"}, _scope, _channel_pid}
    end

    test "requires a stable client id from an otherwise authorized subscriber" do
      permissions = [Channel.subscribe_permission()]
      socket = socket_with_replay(permissions, MapSet.new(permissions))

      assert {:error, %{reason: "client_id_required"}} = Channel.join(@firehose, %{}, socket)
    end

    test "preserves a structured cursor gap and its signed earliest cursor" do
      permissions = [Channel.subscribe_permission()]
      socket = socket_with_replay(permissions, MapSet.new(permissions))

      assert {:error, %{reason: "cursor_gap", earliest_cursor: "signed-earliest-cursor"}} =
               Channel.join(
                 @firehose,
                 %{"client_id" => "browser-profile-1", "cursor" => "behind-retention"},
                 socket
               )
    end
  end

  describe "filter_envelope/2" do
    test "passes the rendered payload to a subscriber who may read deliveries" do
      filtered = Channel.filter_envelope(@envelope, %{payload?: true})

      assert filtered["payload"] == @envelope["payload"]
    end

    test "drops the rendered payload from a subscriber who may not read deliveries" do
      # Otherwise the firehose is a second, unaudited read path around the
      # Delivery Log's own read policy.
      filtered = Channel.filter_envelope(@envelope, %{payload?: false})

      refute Map.has_key?(filtered, "payload")
    end

    test "keeps the identifiers a subscriber resolves through the authenticated API" do
      filtered = Channel.filter_envelope(@envelope, %{payload?: false})

      assert filtered["alert_id"] == "alert-1"
      assert filtered["delivery_id"] == "delivery-1"
      assert filtered["channel_id"] == "channel-1"
    end

    test "strips an action link or capability token even when one reaches it" do
      # The transport refuses to put one on the wire and strips them itself. This
      # is the third guard, and it exists because an invariant that depends on
      # its caller remembering is not an invariant.
      leaked =
        Map.put(@envelope, "payload", %{
          "subject" => "Disk pressure",
          "acknowledge_url" => "https://sr.example.com/notifications/actions/ack?token=secret",
          "capability_token" => "secret"
        })

      encoded =
        leaked
        |> Channel.filter_envelope(%{payload?: true})
        |> Jason.encode!()

      refute encoded =~ "capability_token"
      refute encoded =~ "acknowledge_url"
      refute encoded =~ "secret"
    end

    test "strips action links for an unprivileged subscriber too" do
      leaked = Map.put(@envelope, "capability_token", "secret")

      encoded =
        leaked
        |> Channel.filter_envelope(%{payload?: false})
        |> Jason.encode!()

      refute encoded =~ "secret"
    end
  end

  describe "authorize_envelope/2" do
    test "stops the feed when subscribe permission is revoked after join" do
      # Model the joined socket directly: its cached scope still has both grants
      # while the current authority has already revoked them.
      socket =
        socket_with(
          [Channel.subscribe_permission(), Channel.payload_permission()],
          MapSet.new()
        )

      assert {:error, :permission_revoked, ^socket} =
               Channel.authorize_envelope(@envelope, socket)
    end

    test "removes payload immediately when only delivery-view permission is revoked" do
      current_permissions = MapSet.new([Channel.subscribe_permission()])

      socket =
        socket_with(
          [Channel.subscribe_permission(), Channel.payload_permission()],
          current_permissions
        )

      assert {:ok, filtered, refreshed_socket} = Channel.authorize_envelope(@envelope, socket)
      refute Map.has_key?(filtered, "payload")
      refute refreshed_socket.assigns.firehose_payload?
    end
  end

  describe "durable replay delivery" do
    test "acknowledges a replay record only after the client confirms its exact cursor" do
      permissions = [Channel.subscribe_permission(), Channel.payload_permission()]
      socket = socket_with_push(permissions, MapSet.new(permissions))
      reply_ref = make_ref()

      assert {:noreply, pending_socket} =
               Channel.handle_info(
                 {:firehose_replay, @envelope, %{stream_sequence: 9}, self(), reply_ref},
                 socket
               )

      assert_receive {:pushed, "notification", @envelope}
      assert_receive {:pushed, "notification_cursor", %{"cursor" => "signed-cursor-10", "delivery_id" => "delivery-1"}}

      refute_receive {:firehose_replay_result, ^reply_ref, _outcome}

      assert {:reply, {:ok, %{cursor: "signed-cursor-10", delivery_id: "delivery-1"}}, acknowledged_socket} =
               Channel.handle_in(
                 "notification_ack",
                 %{"cursor" => "signed-cursor-10"},
                 pending_socket
               )

      assert acknowledged_socket.assigns.firehose_pending_ack == nil
      assert_receive {:firehose_replay_result, ^reply_ref, :ack}
    end

    test "leaves replay unacknowledged and stops when authority was revoked" do
      cached_permissions = [Channel.subscribe_permission(), Channel.payload_permission()]
      socket = socket_with_push(cached_permissions, MapSet.new())
      reply_ref = make_ref()

      assert {:stop, :permission_revoked, ^socket} =
               Channel.handle_info(
                 {:firehose_replay, @envelope, %{stream_sequence: 10}, self(), reply_ref},
                 socket
               )

      assert_receive {:firehose_replay_result, ^reply_ref, :leave_unacked}
      refute_receive {:pushed, "notification", _envelope}
      refute_receive {:pushed, "notification_cursor", _cursor}
    end

    test "deduplicates a repeated durable envelope while advancing each cursor" do
      permissions = [Channel.subscribe_permission(), Channel.payload_permission()]
      socket = socket_with_push(permissions, MapSet.new(permissions))
      first_reply_ref = make_ref()

      assert {:noreply, pending_socket} =
               Channel.handle_info(
                 {:firehose_replay, @envelope, %{stream_sequence: 11}, self(), first_reply_ref},
                 socket
               )

      assert_receive {:pushed, "notification", @envelope}

      assert_receive {:pushed, "notification_cursor", %{"cursor" => "signed-cursor-12", "delivery_id" => "delivery-1"}}

      assert {:reply, {:ok, _ack}, socket} =
               Channel.handle_in(
                 "notification_ack",
                 %{"cursor" => "signed-cursor-12"},
                 pending_socket
               )

      assert_receive {:firehose_replay_result, ^first_reply_ref, :ack}

      duplicate_reply_ref = make_ref()

      assert {:noreply, duplicate_pending_socket} =
               Channel.handle_info(
                 {:firehose_replay, @envelope, %{stream_sequence: 12}, self(), duplicate_reply_ref},
                 socket
               )

      refute_receive {:pushed, "notification", _duplicate}

      assert_receive {:pushed, "notification_cursor", %{"cursor" => "signed-cursor-13", "delivery_id" => "delivery-1"}}

      assert {:reply, {:ok, _ack}, _socket} =
               Channel.handle_in(
                 "notification_ack",
                 %{"cursor" => "signed-cursor-13"},
                 duplicate_pending_socket
               )

      assert_receive {:firehose_replay_result, ^duplicate_reply_ref, :ack}
    end

    test "keeps a record pending when the client acknowledges a different cursor" do
      permissions = [Channel.subscribe_permission(), Channel.payload_permission()]
      socket = socket_with_push(permissions, MapSet.new(permissions))
      reply_ref = make_ref()

      assert {:noreply, pending_socket} =
               Channel.handle_info(
                 {:firehose_replay, @envelope, %{stream_sequence: 12}, self(), reply_ref},
                 socket
               )

      assert {:reply, {:error, %{reason: "cursor_mismatch"}}, still_pending} =
               Channel.handle_in(
                 "notification_ack",
                 %{"cursor" => "signed-cursor-999"},
                 pending_socket
               )

      assert still_pending.assigns.firehose_pending_ack.cursor == "signed-cursor-13"
      assert still_pending.assigns.firehose_pending_ack.delivery_id == "delivery-1"
      refute_receive {:firehose_replay_result, ^reply_ref, _outcome}
    end

    test "an ACK timeout emits overflow, leaves the record pending, and stops" do
      permissions = [Channel.subscribe_permission(), Channel.payload_permission()]
      socket = socket_with_push(permissions, MapSet.new(permissions))
      reply_ref = make_ref()

      assert {:noreply, pending_socket} =
               Channel.handle_info(
                 {:firehose_replay, @envelope, %{stream_sequence: 13}, self(), reply_ref},
                 socket
               )

      assert {:stop, :notification_ack_timeout, stopped_socket} =
               Channel.handle_info({:firehose_ack_timeout, reply_ref}, pending_socket)

      assert stopped_socket.assigns.firehose_pending_ack == nil

      assert_receive {:pushed, "notification_overflow",
                      %{
                        "cursor" => "signed-cursor-14",
                        "delivery_id" => "delivery-1",
                        "reason" => "ack_timeout"
                      }}

      assert_receive {:firehose_replay_result, ^reply_ref, :leave_unacked}
    end

    test "ignores the PubSub data path before durable pending state exists" do
      permissions = [Channel.subscribe_permission(), Channel.payload_permission()]
      socket = socket_with_push(permissions, MapSet.new(permissions))

      assert {:noreply, ^socket} =
               Channel.handle_info({:notification_envelope, @envelope}, socket)

      refute_receive {:pushed, "notification", _envelope}
    end

    test "keeps the duplicate window bounded on a long-lived socket" do
      permissions = [Channel.subscribe_permission(), Channel.payload_permission()]
      socket = socket_with_push(permissions, MapSet.new(permissions))

      socket =
        Enum.reduce(1..(Channel.dedupe_limit() + 1), socket, fn index, socket ->
          delivery_id = "delivery-#{index}"
          envelope = Map.put(@envelope, "delivery_id", delivery_id)
          reply_ref = make_ref()

          assert {:noreply, pending_socket} =
                   Channel.handle_info(
                     {:firehose_replay, envelope, %{stream_sequence: index}, self(), reply_ref},
                     socket
                   )

          assert_receive {:pushed, "notification", ^envelope}

          cursor = "signed-cursor-#{index + 1}"

          assert_receive {:pushed, "notification_cursor", %{"cursor" => ^cursor, "delivery_id" => ^delivery_id}}

          assert {:reply, {:ok, _ack}, socket} =
                   Channel.handle_in(
                     "notification_ack",
                     %{"cursor" => cursor},
                     pending_socket
                   )

          assert_receive {:firehose_replay_result, ^reply_ref, :ack}
          socket
        end)

      seen = socket.assigns.firehose_seen.ids

      assert MapSet.size(seen) == Channel.dedupe_limit()
      refute MapSet.member?(seen, {:delivery, "delivery-1"})

      assert MapSet.member?(
               seen,
               {:delivery, "delivery-#{Channel.dedupe_limit() + 1}"}
             )
    end
  end
end
