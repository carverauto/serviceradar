defmodule ServiceRadarWebNG.Notifications.FirehoseReplayTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Notifications.FirehoseReplay
  alias ServiceRadarWebNG.Notifications.FirehoseReplayConsumer

  @moduletag :db_free

  @topic "notifications:stream"
  @subject "notifications.stream"
  @stream_info "$JS.API.STREAM.INFO.NOTIFICATIONS"
  @token_secret String.duplicate("cursor-test-secret-", 4)

  setup_all do
    {:ok, _started} = Application.ensure_all_started(:plug_crypto)
    :ok
  end

  defp scope(user_id \\ "user-1", tenant_id \\ "tenant-1") do
    Scope.for_user(
      %{id: user_id, email: "operator@example.test"},
      identity_claims: %{"tenant_id" => tenant_id}
    )
  end

  defp absent_consumer do
    %{"error" => %{"err_code" => 10_014, "description" => "consumer not found"}}
  end

  defp present_consumer do
    %{
      "ack_floor" => %{"stream_seq" => 24},
      "config" => %{
        "deliver_policy" => "by_start_sequence",
        "filter_subject" => @subject,
        "opt_start_seq" => 21
      }
    }
  end

  defp broker_opts(opts \\ []) do
    test_pid = self()
    stream_state = Keyword.get(opts, :stream_state, %{"first_seq" => 10, "last_seq" => 20})
    stream_created = Keyword.get(opts, :stream_created, "2026-08-11T00:00:00Z")
    consumer_response = Keyword.get(opts, :consumer_response, absent_consumer())

    [
      connection: fn -> {:ok, :fake_gnat} end,
      connection_name: :fake_gnat,
      cursor_token_context: @token_secret,
      ensure_stream: fn connection ->
        send(test_pid, {:stream_ensured, connection})
        :ok
      end,
      js_request: fn connection, subject, payload ->
        send(test_pid, {:js_request, connection, subject, payload})

        cond do
          subject == @stream_info ->
            {:ok, %{"created" => stream_created, "state" => stream_state}}

          String.contains?(subject, ".CONSUMER.INFO.") ->
            broker_response(consumer_response)

          String.contains?(subject, ".CONSUMER.DELETE.") ->
            {:ok, %{"success" => true}}

          String.contains?(subject, ".CONSUMER.DURABLE.CREATE.") ->
            {:ok, %{"name" => "created"}}

          true ->
            {:error, {:unexpected_subject, subject}}
        end
      end,
      consumer_start: fn init ->
        send(test_pid, {:started, init})
        {:ok, test_pid}
      end
    ]
  end

  defp broker_response({status, _value} = response) when status in [:ok, :error], do: response
  defp broker_response(response), do: {:ok, response}

  defp create_request(consumer_name) do
    "$JS.API.CONSUMER.DURABLE.CREATE.NOTIFICATIONS.#{consumer_name}"
  end

  defp info_request(consumer_name) do
    "$JS.API.CONSUMER.INFO.NOTIFICATIONS.#{consumer_name}"
  end

  defp delete_request(consumer_name) do
    "$JS.API.CONSUMER.DELETE.NOTIFICATIONS.#{consumer_name}"
  end

  test "a new no-cursor durable starts at the stream tail plus one" do
    payload = %{"client_id" => "browser-profile-1"}

    assert {:ok, replay} =
             FirehoseReplay.start(@topic, payload, scope(), self(), broker_opts())

    assert replay.consumer_name =~ ~r/\Asr-firehose-v2-[0-9a-f]{48}\z/
    assert is_binary(replay.initial_cursor)
    assert_received {:stream_ensured, :fake_gnat}
    assert_received {:js_request, :fake_gnat, @stream_info, ""}
    assert_received {:js_request, :fake_gnat, info_subject, ""}
    assert info_subject == info_request(replay.consumer_name)
    assert_received {:js_request, :fake_gnat, create_subject, create_payload}
    assert create_subject == create_request(replay.consumer_name)

    config = Jason.decode!(create_payload)["config"]
    assert config["deliver_policy"] == "by_start_sequence"
    assert config["opt_start_seq"] == 21
    assert config["filter_subject"] == @subject
    assert config["inactive_threshold"] == 172_800_000_000_000
    assert config["max_ack_pending"] == 1
    assert config["max_deliver"] == -1

    assert_received {:started, started}
    assert started.consumer_name == replay.consumer_name
    assert started.stream_name == "NOTIFICATIONS"
  end

  test "a reconnect without a cursor resumes the existing v2 durable" do
    payload = %{"client_id" => "browser-profile-1"}

    opts =
      broker_opts(
        consumer_response: present_consumer(),
        stream_state: %{"first_seq" => 10, "last_seq" => 30}
      )

    assert {:ok, first} = FirehoseReplay.start(@topic, payload, scope(), self(), opts)
    assert_received {:js_request, :fake_gnat, first_info, ""}
    assert first_info == @stream_info
    assert_received {:js_request, :fake_gnat, consumer_info, ""}
    assert consumer_info == info_request(first.consumer_name)

    refute_received {:js_request, :fake_gnat, "$JS.API.CONSUMER.DURABLE.CREATE.NOTIFICATIONS." <> _, _payload}

    assert {:ok, second} = FirehoseReplay.start(@topic, payload, scope(), self(), opts)
    assert first.consumer_name == second.consumer_name
    assert is_binary(second.initial_cursor)
  end

  test "a new durable's join cursor rewinds to its tail baseline" do
    payload = %{"client_id" => "browser-profile-1"}

    assert {:ok, replay} =
             FirehoseReplay.start(@topic, payload, scope(), self(), broker_opts())

    first_create = create_request(replay.consumer_name)
    assert_received {:js_request, :fake_gnat, ^first_create, _first_payload}

    reconnect_opts = broker_opts(consumer_response: present_consumer())

    assert {:ok, _reconnected} =
             FirehoseReplay.start(
               @topic,
               Map.put(payload, "cursor", replay.initial_cursor),
               scope(),
               self(),
               reconnect_opts
             )

    create_subject = create_request(replay.consumer_name)
    assert_received {:js_request, :fake_gnat, ^create_subject, create_payload}
    assert get_in(Jason.decode!(create_payload), ["config", "opt_start_seq"]) == 21
  end

  test "the existing durable's join cursor rewinds to its acknowledged floor" do
    payload = %{"client_id" => "browser-profile-1"}

    opts =
      broker_opts(
        consumer_response: present_consumer(),
        stream_state: %{"first_seq" => 10, "last_seq" => 30}
      )

    assert {:ok, replay} = FirehoseReplay.start(@topic, payload, scope(), self(), opts)

    assert {:ok, _reconnected} =
             FirehoseReplay.start(
               @topic,
               Map.put(payload, "cursor", replay.initial_cursor),
               scope(),
               self(),
               opts
             )

    delete_subject = delete_request(replay.consumer_name)
    assert_received {:js_request, :fake_gnat, ^delete_subject, ""}
    create_subject = create_request(replay.consumer_name)
    assert_received {:js_request, :fake_gnat, ^create_subject, create_payload}
    assert get_in(Jason.decode!(create_payload), ["config", "opt_start_seq"]) == 25
  end

  test "a signed cursor is authoritative and recreates the v2 durable at next_seq" do
    payload = %{"client_id" => "browser-profile-1"}

    assert {:ok, replay} =
             FirehoseReplay.start(@topic, payload, scope(), self(), broker_opts())

    assert {:ok, cursor} = FirehoseReplay.cursor_token(replay, 15)

    # Consume the first start's create request before asserting the reset.
    first_create = create_request(replay.consumer_name)
    assert_received {:js_request, :fake_gnat, ^first_create, _first_payload}

    reconnect_opts = broker_opts(consumer_response: present_consumer())

    assert {:ok, reconnected} =
             FirehoseReplay.start(
               @topic,
               %{"client_id" => "browser-profile-1", "cursor" => cursor},
               scope(),
               self(),
               reconnect_opts
             )

    assert reconnected.consumer_name == replay.consumer_name
    delete_subject = delete_request(replay.consumer_name)
    assert_received {:js_request, :fake_gnat, ^delete_subject, ""}
    create_subject = create_request(replay.consumer_name)
    assert_received {:js_request, :fake_gnat, ^create_subject, create_payload}
    assert get_in(Jason.decode!(create_payload), ["config", "opt_start_seq"]) == 15
  end

  test "a cursor is bound to tenant, user, topic, and client id" do
    assert {:ok, replay} =
             FirehoseReplay.start(
               @topic,
               %{"client_id" => "client-1"},
               scope(),
               self(),
               broker_opts()
             )

    assert {:ok, cursor} = FirehoseReplay.cursor_token(replay, 15)

    no_broker = [
      connection: fn -> flunk("an invalid binding must fail before NATS") end,
      cursor_token_context: @token_secret
    ]

    for {other_scope, other_topic, other_client} <- [
          {scope("user-1", "tenant-2"), @topic, "client-1"},
          {scope("user-2", "tenant-1"), @topic, "client-1"},
          {scope(), @topic <> ":ops", "client-1"},
          {scope(), @topic, "client-2"}
        ] do
      assert {:error, :invalid_cursor} =
               FirehoseReplay.start(
                 other_topic,
                 %{"client_id" => other_client, "cursor" => cursor},
                 other_scope,
                 self(),
                 no_broker
               )
    end
  end

  test "a cursor behind retention returns a signed earliest cursor" do
    assert {:ok, replay} =
             FirehoseReplay.start(
               @topic,
               %{"client_id" => "client-1"},
               scope(),
               self(),
               broker_opts(stream_state: %{"first_seq" => 1, "last_seq" => 20})
             )

    assert {:ok, stale_cursor} = FirehoseReplay.cursor_token(replay, 5)
    initial_create = create_request(replay.consumer_name)
    assert_received {:js_request, :fake_gnat, ^initial_create, _initial_payload}

    retained = broker_opts(stream_state: %{"first_seq" => 10, "last_seq" => 30})

    assert {:error, {:cursor_gap, earliest_cursor}} =
             FirehoseReplay.start(
               @topic,
               %{"client_id" => "client-1", "cursor" => stale_cursor},
               scope(),
               self(),
               retained
             )

    # The returned cursor is signed for this subscriber and starts exactly at
    # the earliest globally retained stream sequence.
    assert {:ok, resumed} =
             FirehoseReplay.start(
               @topic,
               %{"client_id" => "client-1", "cursor" => earliest_cursor},
               scope(),
               self(),
               retained
             )

    create_subject = create_request(resumed.consumer_name)
    assert_received {:js_request, :fake_gnat, ^create_subject, create_payload}
    assert get_in(Jason.decode!(create_payload), ["config", "opt_start_seq"]) == 10
  end

  test "a same-generation cursor beyond the current tail is rejected" do
    opts = broker_opts()

    assert {:ok, replay} =
             FirehoseReplay.start(
               @topic,
               %{"client_id" => "client-1"},
               scope(),
               self(),
               opts
             )

    assert {:ok, future_cursor} = FirehoseReplay.cursor_token(replay, 50)

    assert {:error, {:cursor_gap, earliest_cursor}} =
             FirehoseReplay.start(
               @topic,
               %{"client_id" => "client-1", "cursor" => future_cursor},
               scope(),
               self(),
               opts
             )

    assert is_binary(earliest_cursor)
  end

  test "a cursor beyond a recreated stream returns its signed reset baseline" do
    assert {:ok, replay} =
             FirehoseReplay.start(
               @topic,
               %{"client_id" => "client-1"},
               scope(),
               self(),
               broker_opts(stream_state: %{"first_seq" => 1, "last_seq" => 100})
             )

    assert {:ok, old_generation_cursor} = FirehoseReplay.cursor_token(replay, 80)
    initial_create = create_request(replay.consumer_name)
    assert_received {:js_request, :fake_gnat, ^initial_create, _initial_payload}

    reset_stream =
      broker_opts(
        stream_created: "2026-08-12T00:00:00Z",
        stream_state: %{"first_seq" => 1, "last_seq" => 100}
      )

    assert {:error, {:cursor_gap, earliest_cursor}} =
             FirehoseReplay.start(
               @topic,
               %{"client_id" => "client-1", "cursor" => old_generation_cursor},
               scope(),
               self(),
               reset_stream
             )

    assert {:ok, reset_replay} =
             FirehoseReplay.start(
               @topic,
               %{"client_id" => "client-1", "cursor" => earliest_cursor},
               scope(),
               self(),
               reset_stream
             )

    create_subject = create_request(reset_replay.consumer_name)
    assert_received {:js_request, :fake_gnat, ^create_subject, create_payload}
    assert get_in(Jason.decode!(create_payload), ["config", "opt_start_seq"]) == 1
  end

  test "only JetStream err_code 10014 means the consumer is absent" do
    payload = %{"client_id" => "client-1"}

    assert {:ok, _replay} =
             FirehoseReplay.start(@topic, payload, scope(), self(), broker_opts())

    assert {:error, {:consumer_info_failed, %{"err_code" => 10_008}}} =
             FirehoseReplay.start(
               @topic,
               payload,
               scope(),
               self(),
               broker_opts(consumer_response: %{"error" => %{"err_code" => 10_008}})
             )

    assert {:error, {:consumer_info_failed, :timeout}} =
             FirehoseReplay.start(
               @topic,
               payload,
               scope(),
               self(),
               broker_opts(consumer_response: {:error, :timeout})
             )
  end

  test "durables are isolated by tenant, user, client, and topic" do
    assert {:ok, base} = FirehoseReplay.durable_name(scope(), @topic, "client-1")

    assert {:ok, other_tenant} =
             FirehoseReplay.durable_name(scope("user-1", "tenant-2"), @topic, "client-1")

    assert {:ok, other_user} = FirehoseReplay.durable_name(scope("user-2"), @topic, "client-1")
    assert {:ok, other_client} = FirehoseReplay.durable_name(scope(), @topic, "client-2")
    assert {:ok, other_topic} = FirehoseReplay.durable_name(scope(), @topic <> ":ops", "client-1")

    assert [base, other_tenant, other_user, other_client, other_topic]
           |> Enum.uniq()
           |> length() == 5

    assert base =~ ~r/\Asr-firehose-v2-[0-9a-f]{48}\z/
    refute base =~ "tenant-1"
    refute base =~ "user-1"
    refute base =~ "client-1"
  end

  test "ignores caller-supplied durable and consumer names" do
    payload = %{
      "client_id" => "client-1",
      "consumer_name" => "victim-consumer",
      "durable_name" => "victim-durable"
    }

    assert {:ok, replay} =
             FirehoseReplay.start(@topic, payload, scope(), self(), broker_opts())

    refute replay.consumer_name in ["victim-consumer", "victim-durable"]
  end

  test "fails closed when the publisher-owned wildcard stream cannot be provisioned" do
    opts = [
      connection: fn -> {:ok, :fake_gnat} end,
      ensure_stream: fn :fake_gnat -> {:error, :stream_unavailable} end,
      js_request: fn _connection, _subject, _payload ->
        flunk("JetStream must not be inspected after stream provisioning fails")
      end
    ]

    assert {:error, :stream_unavailable} =
             FirehoseReplay.start(
               @topic,
               %{"client_id" => "client-1"},
               scope(),
               self(),
               opts
             )
  end

  test "rejects missing or malformed client ids before touching NATS" do
    opts = [connection: fn -> flunk("NATS must not be consulted") end]

    assert {:error, :client_id_required} =
             FirehoseReplay.start(@topic, %{}, scope(), self(), opts)

    for client_id <- ["", " has-space", "wild*card", String.duplicate("a", 129)] do
      assert {:error, :invalid_client_id} =
               FirehoseReplay.start(@topic, %{"client_id" => client_id}, scope(), self(), opts)
    end
  end

  test "pull consumer heartbeat watchdog exceeds the client ACK wait" do
    assert {:ok, state, consumer_opts} =
             FirehoseReplayConsumer.init(%{
               channel_pid: self(),
               connection_name: :fake_gnat,
               consumer_name: "sr-firehose-v2-test",
               stream_name: "NOTIFICATIONS"
             })

    assert consumer_opts[:batch_size] == 1
    assert consumer_opts[:request_expires] == 60_000_000_000
    assert consumer_opts[:idle_heartbeat] == 30_000_000_000
    assert consumer_opts[:idle_heartbeat] <= div(consumer_opts[:request_expires], 2)
    assert 2 * consumer_opts[:idle_heartbeat] > state.reply_timeout_ms * 1_000_000
  end

  test "pull callback waits for the channel decision before acknowledging" do
    test_pid = self()
    # Must outlast everything this test waits on before it replies (an
    # `assert_receive` plus a `refute_receive`, either of which can be
    # stretched by a VM stall). At 1_000 the handler gave up first and
    # returned `:noreply`, failing the result assertion below.
    state = %{channel_pid: test_pid, reply_timeout_ms: 30_000}

    message = %{
      body: Jason.encode!(%{"delivery_id" => "delivery-42"}),
      reply_to: "$JS.ACK.NOTIFICATIONS.sr-firehose-v2.1.42.7.1700000000000000000.3"
    }

    task_pid =
      start_supervised!(
        {Task,
         fn ->
           result = FirehoseReplayConsumer.handle_message(message, state)
           send(test_pid, {:handler_result, result})
         end}
      )

    assert_receive {:firehose_replay, %{"delivery_id" => "delivery-42"}, cursor, ^task_pid, reply_ref}

    assert cursor.stream_sequence == 42
    assert cursor.consumer_sequence == 7
    refute_receive {:handler_result, _result}

    send(task_pid, {:firehose_replay_result, reply_ref, :ack})
    assert_receive {:handler_result, {:ack, ^state}}
  end

  test "pull callback leaves the record pending when replay authorization is revoked" do
    test_pid = self()
    # Must outlast everything this test waits on before it replies (an
    # `assert_receive` plus a `refute_receive`, either of which can be
    # stretched by a VM stall). At 1_000 the handler gave up first and
    # returned `:noreply`, failing the result assertion below.
    state = %{channel_pid: test_pid, reply_timeout_ms: 30_000}
    message = %{body: Jason.encode!(%{"delivery_id" => "delivery-43"}), reply_to: nil}

    task_pid =
      start_supervised!(
        {Task,
         fn ->
           result = FirehoseReplayConsumer.handle_message(message, state)
           send(test_pid, {:handler_result, result})
         end}
      )

    assert_receive {:firehose_replay, %{"delivery_id" => "delivery-43"}, %{}, ^task_pid, reply_ref}

    send(task_pid, {:firehose_replay_result, reply_ref, :leave_unacked})
    assert_receive {:handler_result, {:noreply, ^state}}
  end
end
