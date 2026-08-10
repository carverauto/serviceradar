defmodule ServiceRadarWebNGWeb.NotificationFirehoseChannelTest do
  @moduledoc """
  The firehose subscriber's authorization contract (tasks 4.4.2 and 4.4.2b).

  These run without a database and without a socket: `join/3` refuses an
  unauthorized scope before it touches PubSub, and `filter_envelope/2` is a pure
  function over a map. Asserting either one only through a live socket would mean
  asserting it in a tier that needs infrastructure to run, which is how a
  security assertion quietly stops being run at all.
  """

  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.NotificationFirehoseChannel, as: Channel

  @firehose "notifications:stream"

  @envelope %{
    "schema" => "serviceradar.notification_envelope.v1",
    "alert_id" => "alert-1",
    "delivery_id" => "delivery-1",
    "channel_id" => "channel-1",
    "payload" => %{"subject" => "Disk pressure", "body" => "node-3 at 94%"}
  }

  defp scope(permissions) do
    Scope.for_user(%{id: Ecto.UUID.generate(), email: "operator@example.com"},
      permissions: MapSet.new(permissions)
    )
  end

  defp socket_with(permissions) do
    %Phoenix.Socket{assigns: %{current_scope: scope(permissions)}}
  end

  describe "join/3 authorization" do
    test "refuses a scope without notifications.stream.subscribe" do
      assert {:error, %{reason: "unauthorized"}} =
               Channel.join(@firehose, %{}, socket_with(["notifications.channels.view"]))
    end

    test "refuses a scope with no permissions at all" do
      assert {:error, %{reason: "unauthorized"}} = Channel.join(@firehose, %{}, socket_with([]))
    end

    test "refuses a suffixed topic to a scope without the subscribe permission" do
      # A suffix narrows which envelopes a subscriber receives. It is not a
      # second, weaker way in.
      assert {:error, %{reason: "unauthorized"}} =
               Channel.join(@firehose <> ":ops", %{}, socket_with(["notifications.routes.view"]))
    end

    test "refuses a topic outside the notification namespace" do
      assert {:error, %{reason: "unknown_topic"}} =
               Channel.join("topology:god_view", %{}, socket_with([Channel.subscribe_permission()]))
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
end
