defmodule ServiceRadarWebNG.Topology.BitmapQueryControlTest do
  use ExUnit.Case, async: false

  alias Phoenix.Socket.V2.JSONSerializer
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Topology.BitmapAddress
  alias ServiceRadarWebNG.Topology.BitmapCursor
  alias ServiceRadarWebNG.Topology.BitmapExpression
  alias ServiceRadarWebNG.Topology.BitmapQueries
  alias ServiceRadarWebNG.Topology.BitmapQueryAdmission
  alias ServiceRadarWebNG.Topology.BitmapStream
  alias ServiceRadarWebNG.Topology.BitmapValues
  alias ServiceRadarWebNG.Topology.BitmapView
  alias ServiceRadarWebNG.Topology.Native
  alias ServiceRadarWebNG.Topology.TileWatchTasks
  alias ServiceRadarWebNGWeb.TopologyQueryController
  alias ServiceRadarWebNGWeb.TopologyTileChannel

  @moduletag :db_free

  @facets ["vendor", "region", "availability"]
  @dictionary <<17::128>>
  @epoch <<18::128>>
  @authority <<19::256>>

  test "normalized browser expressions preserve nested exclusions and exact same-facet counts in native queries" do
    expression = %{
      "all" => [
        %{"any" => [predicate("vendor", "example-a"), predicate("region", "example-west")]},
        %{"except" => predicate("availability", "unavailable")}
      ]
    }

    {:ok, parsed} = BitmapExpression.parse(%{"expression" => expression}, @facets)
    reversed = put_in(expression["all"], Enum.reverse(expression["all"]))
    {:ok, equivalent} = BitmapExpression.parse(%{"expression" => reversed}, @facets)
    assert parsed.digest == equivalent.digest

    index =
      index([
        {3, true, [{"vendor", "example-a"}, {"region", "example-east"}, {"availability", "healthy"}]},
        {7, true, [{"vendor", "example-b"}, {"region", "example-west"}, {"availability", "healthy"}]},
        {11, true, [{"vendor", "example-a"}, {"availability", "unavailable"}]},
        {13, false, [{"vendor", "example-a"}]},
        {4_294_967_295, true, [{"vendor", "example-a"}]}
      ])

    assert {:ok, {query, 1, "initial", 3}} = query(index, parsed)
    assert {:ok, [3, 7, 4_294_967_295]} = Native.bitmap_query_page(query, @authority, 0, 128, 1000)

    assert {:ok, [2, 1, 0]} =
             Native.bitmap_query_facets(
               query,
               @authority,
               [
                 {"vendor", "example-a"},
                 {"vendor", "example-b"},
                 {"availability", "unavailable"}
               ],
               1000
             )

    Native.bitmap_query_close(query)
  end

  test "value browsing pages current canonical values and binds cursors to search and authority" do
    index =
      index([
        {1, true, [{"vendor", "Example Alpha"}]},
        {2, true, [{"vendor", "Example Alpha"}]},
        {3, true, [{"vendor", "Example Beta"}]},
        {4, true, [{"vendor", "Other"}]}
      ])

    {:ok, parsed} = BitmapExpression.parse(%{}, @facets)
    {:ok, {ref, _, _, _}} = query(index, parsed)
    context = %{ref: ref, authority: @authority, deadline: now() + 1_000}
    params = %{"facet" => "vendor", "search" => "EXAMPLE", "limit" => "1"}
    assert {:ok, %{items: [%{value: "Example Alpha", count: 2}], cursor: cursor}} = BitmapValues.page(params, context)
    assert is_binary(cursor)
    next = Map.put(params, "cursor", cursor)

    for changed <- [
          Map.put(next, "facet", "region"),
          Map.put(next, "search", "Other"),
          Map.put(next, "cursor", cursor <> "bad")
        ] do
      assert {:error, :invalid_cursor} = BitmapValues.page(changed, context)
    end

    assert {:error, :invalid_cursor} = BitmapValues.page(next, %{context | authority: <<20::256>>})
    Native.bitmap_query_close(ref)

    assert {:ok, _} =
             Native.bitmap_index_publish(
               index,
               1,
               "changed",
               [
                 {3, false, []},
                 {5, true, [{"vendor", "Example Gamma"}]}
               ],
               true
             )

    {:ok, {ref, _, _, _}} = query(index, parsed)
    context = %{context | ref: ref, deadline: now() + 1_000}
    assert {:ok, %{items: [%{value: "Example Gamma", count: 1}], cursor: last_cursor}} = BitmapValues.page(next, context)
    assert is_binary(last_cursor)
    assert {:ok, %{items: [], cursor: nil}} = BitmapValues.page(Map.put(params, "cursor", last_cursor), context)
    assert {:error, :invalid_query} = BitmapValues.page(%{"facet" => String.duplicate("x", 65)}, context)
    assert {:error, "unsupported_facet"} = BitmapValues.page(%{"facet" => "secret"}, context)
    assert {:error, :invalid_page_limit} = BitmapValues.page(%{"facet" => "vendor", "limit" => 51}, context)
    Native.bitmap_query_close(ref)
  end

  test "a sparse dictionary search advances past empty bounded windows without losing later matches" do
    index = index([])
    rows = for i <- 1..1_100, do: {i, true, [{"vendor", "Example " <> String.pad_leading(to_string(i), 4, "0")}]}

    rows
    |> Enum.chunk_every(500)
    |> Enum.reduce(1, fn chunk, revision ->
      assert {:ok, _} = Native.bitmap_index_publish(index, revision, "page", chunk, true)
      revision + 1
    end)

    {:ok, parsed} = BitmapExpression.parse(%{}, @facets)
    {:ok, {ref, _, _, _}} = query(index, parsed)
    context = %{ref: ref, authority: @authority, deadline: now() + 1_000}
    params = %{"facet" => "vendor", "search" => "1100"}
    assert {:ok, %{items: [], cursor: cursor}} = BitmapValues.page(params, context)
    assert is_binary(cursor)

    assert {:ok, %{items: [%{value: "Example 1100", count: 1}], cursor: nil}} =
             BitmapValues.page(Map.put(params, "cursor", cursor), context)

    Native.bitmap_query_close(ref)
  end

  test "a cursor resumes current membership after a revision change and rejects query or authority substitution" do
    {:ok, parsed} = BitmapExpression.parse(%{"expression" => predicate("vendor", "example-a")}, @facets)
    context = %{dictionary_epoch: @dictionary, query_digest: parsed.digest, authority: @authority}
    index = index([{3, true, [{"vendor", "example-a"}]}, {7, true, [{"vendor", "example-a"}]}])

    assert {:ok, {first, 1, "initial", 2}} = query(index, parsed)
    assert {:ok, [3]} = Native.bitmap_query_page(first, @authority, 0, 1, 1000)
    cursor = BitmapCursor.sign(context, 3)
    Native.bitmap_query_close(first)

    assert {:ok, %{revision: 2}} =
             Native.bitmap_index_publish(
               index,
               1,
               "updated",
               [
                 {7, false, []},
                 {11, true, [{"vendor", "example-a"}]}
               ],
               true
             )

    assert {:ok, position} = BitmapCursor.after_ordinal(cursor, context)
    assert {:ok, {second, 2, "updated", 2}} = query(index, parsed)
    assert {:ok, [11]} = Native.bitmap_query_page(second, @authority, position, 128, 1000)
    Native.bitmap_query_close(second)

    for changed <- [
          %{context | authority: <<20::256>>},
          %{context | dictionary_epoch: <<21::128>>},
          %{context | query_digest: <<22::256>>}
        ] do
      assert {:error, :invalid_cursor} = BitmapCursor.after_ordinal(cursor, changed)
    end

    assert {:error, :invalid_cursor} = BitmapCursor.after_ordinal(cursor <> "tampered", context)
  end

  test "source hosts and canonical query networks share typed address identity without DNS" do
    assert {:ok, <<192, 0, 2, 7>>} = BitmapAddress.source("192.0.2.7/24")
    assert {:ok, <<192, 0, 2, 7>>} = BitmapAddress.source("::ffff:192.0.2.7")
    assert {:ok, <<0xFE80::16, 0::96, 7::16>>} = BitmapAddress.source("fe80::7%example0/64")
    assert {:ok, <<192, 0, 2, 0>>, 24} = BitmapAddress.cidr("192.0.2.7/24")
    assert {:ok, <<192, 0, 2, 0>>, 24} = BitmapAddress.cidr("::ffff:192.0.2.7/120")
    assert {:ok, <<0::128>>, 0} = BitmapAddress.cidr("2001:db8::7/0")

    assert {:ok, first} = BitmapExpression.parse(%{"expression" => %{"ip_cidr" => "192.0.2.7/24"}}, @facets)
    assert {:ok, mapped} = BitmapExpression.parse(%{"expression" => %{"ip_cidr" => "::ffff:192.0.2.9/120"}}, @facets)
    assert first.digest == mapped.digest

    for value <- [
          "router.example.com",
          "127.1",
          "192.0.2.7/",
          "192.0.2.7/33",
          "fe80::7%example0/64",
          "::ffff:192.0.2.7/95"
        ] do
      assert {:error, :invalid_cidr} = BitmapExpression.parse(%{"expression" => %{"ip_cidr" => value}}, @facets)
    end

    for value <- [" 192.0.2.0/24 ", "192.0.2.0/24 "] do
      assert {:error, :invalid_predicate} = BitmapExpression.parse(%{"expression" => %{"ip_cidr" => value}}, @facets)
      assert {:error, :invalid_cidr} = BitmapAddress.cidr(value)
    end

    assert {:error, :invalid_address} = BitmapAddress.source("router.example.com")
  end

  test "channel membership budgets the query and tile receipts separately" do
    version = "00000000-0000-4000-8000-000000000478"
    revision = String.duplicate("ab", 32)
    query = %{"expression" => %{"all" => []}, "padding" => String.duplicate("q", 12_000)}

    tiles =
      for x <- 0..7, y <- 0..7 do
        %{"z" => 6, "x" => x, "y" => y, "revision" => revision}
      end

    params = %{"protocol" => 1, "layout_version" => version, "tiles" => tiles, "query" => query}
    assert {:ok, %{layout_version: ^version, boundary_endpoints: false}} = BitmapView.validate(params)
    assert {:ok, %{boundary_endpoints: true}} = BitmapView.validate(Map.put(params, "boundary_endpoints", true))

    assert {:error, :query_budget} =
             BitmapView.validate(%{params | "query" => Map.put(query, "padding", String.duplicate("q", 20_000))})

    assert {:error, :query_budget} =
             BitmapView.validate(Map.put(params, "padding", String.duplicate("r", 80_000)))
  end

  test "channel errors use the HTTP reason allowlist and keep transient membership reasons" do
    assert BitmapQueries.public_reason(:forbidden) == "forbidden"
    assert BitmapQueries.public_reason(:query_busy) == "query_busy"
    assert BitmapQueries.public_reason(:source_changed) == "source_changed"
    assert BitmapQueries.public_reason(:membership_replaced) == "membership_replaced"
    assert BitmapQueries.public_reason(:membership_not_ready) == "membership_not_ready"
    assert BitmapQueries.public_reason("text_budget") == "query_unavailable"
    assert BitmapQueries.public_reason(:allocation_failed) == "query_unavailable"
  end

  test "stale channel reset preserves the current watch while its own reset clears and emits a binary frame" do
    metadata = %{
      dictionary_epoch: "synthetic-dictionary",
      index_epoch: "synthetic-index",
      query_digest: "synthetic-query",
      authority_fingerprint: "synthetic-authority",
      view_digest: "current-view",
      source_revision: "synthetic-source",
      index_revision: "1",
      sequence: 1,
      total: 0
    }

    socket =
      BitmapStream.init(%Phoenix.Socket{
        topic: "topology:tiles",
        join_ref: "1",
        joined: true,
        transport_pid: self(),
        serializer: JSONSerializer
      })

    state = %{socket.assigns.bitmap_stream | metadata: metadata, request: %{"query" => %{"all" => []}}, awaiting: 10}
    socket = Phoenix.Socket.assign(socket, :bitmap_stream, state)

    assert {:reply, :ok, ^socket} =
             TopologyTileChannel.handle_in("membership:reset", %{"view_digest" => "previous-view"}, socket)

    refute_receive {:socket_push, _, _}

    assert {:reply, :ok, cleared} =
             TopologyTileChannel.handle_in("membership:reset", %{"view_digest" => "current-view"}, socket)

    assert %{request: nil, metadata: nil, awaiting: nil} = cleared.assigns.bitmap_stream
    assert_receive {:socket_push, :binary, <<0, 1, 14, 16, "1topology:tilesmembership:frame", "SRMO", 1, 1, _::binary>>}
  end

  test "cancelled and timed-out membership tasks keep their slot until completion" do
    keys = [:god_view_enabled]
    previous = Map.new(keys, &{&1, Application.fetch_env(:serviceradar_web_ng, &1)})
    for key <- keys, do: Application.put_env(:serviceradar_web_ng, key, true)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:serviceradar_web_ng, key, value)
        {key, :error} -> Application.delete_env(:serviceradar_web_ng, key)
      end)
    end)

    start_supervised!({Task.Supervisor, name: TileWatchTasks, max_children: 8})

    {:ok, held} =
      Task.Supervisor.start_child(TileWatchTasks, fn ->
        receive do
          :release -> :ok
        end
      end)

    token = make_ref()
    version = "00000000-0000-4000-8000-000000000478"
    revision = String.duplicate("ab", 32)

    params = %{
      "protocol" => 1,
      "layout_version" => version,
      "query" => %{"all" => []},
      "tiles" => [%{"z" => 6, "x" => 0, "y" => 0, "revision" => revision}]
    }

    socket =
      BitmapStream.init(%Phoenix.Socket{
        topic: "topology:tiles",
        join_ref: "1",
        joined: true,
        transport_pid: self(),
        ref: "1",
        serializer: JSONSerializer,
        assigns: %{current_scope: %Scope{user: %{id: "synthetic-viewer"}}}
      })

    state = %{
      socket.assigns.bitmap_stream
      | task: %{
          pid: held,
          ref: Process.monitor(held),
          token: token,
          deadline: System.monotonic_time(:millisecond) - 1,
          timer: Process.send_after(self(), {:membership_timeout, token}, 60_000)
        }
    }

    # Exercise cancellation at its owner boundary: an admitted database query
    # has a real deadline and cannot be held by suspending its index owner.
    socket =
      Phoenix.Socket.assign(socket, :bitmap_stream, %{
        state
        | request: params,
          reply: Phoenix.Channel.socket_ref(socket)
      })

    events = List.flatten(List.duplicate(["membership:unwatch", "membership:reset"], 4))

    cancelled =
      Enum.reduce(events, socket, fn event, current ->
        assert {:reply, :ok, cancelled} = TopologyTileChannel.handle_in(event, %{}, current)
        assert cancelled.assigns.bitmap_stream.request == nil

        assert {:reply, {:error, %{reason: "query_busy"}}, busy} =
                 TopologyTileChannel.handle_in("membership:watch", params, cancelled)

        assert busy.assigns.bitmap_stream.task.pid == held
        assert Process.alive?(held)
        busy
      end)

    assert_receive {:socket_push, :text, reply}

    assert Jason.decode!(IO.iodata_to_binary(reply)) == [
             "1",
             "1",
             "topology:tiles",
             "phx_reply",
             %{"status" => "error", "response" => %{"reason" => "membership_replaced"}}
           ]

    refute_receive {:socket_push, _, _}

    assert {:noreply, completed} =
             TopologyTileChannel.handle_info({:membership_built, token, {:ok, %{frame: "late"}}}, cancelled)

    assert completed.assigns.bitmap_stream.task == nil
    refute_receive {:socket_push, _, _}

    # Restore a monitored slot to cover timeout independently of cancellation.
    state = %{state | task: %{state.task | ref: Process.monitor(held)}}
    socket = Phoenix.Socket.assign(socket, :bitmap_stream, state)

    assert {:noreply, timed_out} = TopologyTileChannel.handle_info({:membership_timeout, token}, socket)
    assert %{pid: ^held, abandoned: true} = timed_out.assigns.bitmap_stream.task
    refute_receive {:socket_push, _, _}

    displayed = %{
      dictionary_epoch: "synthetic-dictionary",
      index_epoch: "synthetic-index",
      query_digest: "synthetic-query",
      authority_fingerprint: "synthetic-authority",
      view_digest: "current-view",
      source_revision: "synthetic-source",
      index_revision: "1",
      sequence: 1,
      total: 0
    }

    kept_request = %{"query" => %{"all" => []}}

    timed_out =
      Phoenix.Socket.assign(timed_out, :bitmap_stream, %{
        timed_out.assigns.bitmap_stream
        | metadata: displayed,
          request: kept_request
      })

    observe_busy()

    assert {:reply, {:error, %{reason: "query_busy"}}, busy} =
             TopologyTileChannel.handle_in("membership:watch", params, timed_out)

    assert_receive {:query_busy, :stream_occupied}

    assert busy.assigns.bitmap_stream.task.pid == held
    assert busy.assigns.bitmap_stream.metadata == displayed
    assert busy.assigns.bitmap_stream.request == kept_request
    refute_receive {:socket_push, _, _}

    assert {:noreply, released} =
             TopologyTileChannel.handle_info({:membership_built, token, {:ok, %{frame: "late"}}}, busy)

    assert released.assigns.bitmap_stream.task == nil
    refute_receive {:socket_push, _, _}

    assert {:noreply, launched} = TopologyTileChannel.handle_in("membership:watch", params, released)
    assert is_pid(launched.assigns.bitmap_stream.task.pid)
    refute launched.assigns.bitmap_stream.task.pid == held
    Process.exit(launched.assigns.bitmap_stream.task.pid, :kill)
    send(held, :release)
  end

  test "prefix controls reject surrounding whitespace and keep internal spaces literal" do
    assert {:error, :invalid_predicate} =
             BitmapExpression.parse(%{"expression" => %{"tag_key_prefix" => " role", "prefix" => " edge "}}, @facets)

    assert {:error, :invalid_predicate} =
             BitmapExpression.parse(%{"expression" => %{"facet" => "vendor", "value" => " ExampleVendor"}}, @facets)

    assert {:ok, spaced} =
             BitmapExpression.parse(
               %{"expression" => %{"tag_key_prefix" => "team", "prefix" => "edge router"}},
               @facets
             )

    assert {:ok, exact} =
             BitmapExpression.parse(%{"expression" => %{"tag_key_prefix" => "role", "value" => "edge"}}, @facets)

    refute exact.digest == spaced.digest

    assert {:ok, _tagged} =
             BitmapExpression.parse(
               %{"expression" => %{"prefix_tag" => %{"source" => "manual", "label" => "edge router"}}},
               @facets
             )

    for expression <- [
          %{"facet" => "vendor", "prefix" => " "},
          %{"tag_key_prefix" => ""},
          %{"tag_key_prefix" => "role", "prefix" => "edge", "value" => "edge"},
          %{"prefix_tag" => %{"source" => "manual", "label" => "example", "extra" => true}},
          %{"prefix_tag" => %{"source" => " manual", "label" => "example"}},
          %{"prefix_tag" => %{"source" => "manual", "label" => " example"}}
        ] do
      assert {:error, :invalid_predicate} = BitmapExpression.parse(%{"expression" => expression}, @facets)
    end

    assert {:ok, label} =
             BitmapExpression.parse(
               %{"expression" => %{"prefix_tag" => %{"source" => "manual", "label" => "example"}}},
               @facets
             )

    assert {:ok, other} =
             BitmapExpression.parse(
               %{"expression" => %{"prefix_tag" => %{"source" => "example-import", "label" => "example"}}},
               @facets
             )

    refute label.digest == other.digest

    assert {:error, :invalid_predicate} =
             BitmapExpression.parse(%{"facets" => [%{"facet" => "vendor", "prefix" => "ex"}]}, @facets)
  end

  test "untrusted control cannot select undeclared fields or bypass expression and request bounds" do
    assert {:error, :invalid_query} = BitmapExpression.parse(%{"metadata.secret" => "x"}, @facets)
    assert {:error, :unsupported_entity} = BitmapExpression.parse(%{"kind" => "interface"}, @facets)

    assert {:error, :unsupported_facet} =
             BitmapExpression.parse(%{"expression" => predicate("metadata.secret", "x")}, @facets)

    assert {:error, :invalid_predicate} =
             BitmapExpression.parse(%{"expression" => %{"facet" => "vendor", "value" => "x", "extra" => true}}, @facets)

    assert {:error, :expression_budget} =
             BitmapExpression.parse(
               %{
                 "expression" => %{
                   "all" => [
                     %{"all" => List.duplicate(predicate("vendor", "example-a"), 32)},
                     predicate("region", "example-west")
                   ]
                 }
               },
               @facets
             )

    assert {:error, :query_budget} =
             BitmapExpression.parse(%{"expression" => predicate("vendor", String.duplicate("x", 16_384))}, @facets)

    assert {:error, :invalid_page_limit} = BitmapExpression.parse(%{"limit" => 129}, @facets)
  end

  test "query and tile selection share bitmap statuses without retrying client errors" do
    unauthorized = TopologyQueryController.create(Plug.Test.conn(:post, "/topology/query"), %{})
    assert unauthorized.status == 401
    assert Jason.decode!(unauthorized.resp_body) == %{"error" => "unauthorized"}
    assert Plug.Conn.get_resp_header(unauthorized, "retry-after") == []
    assert {:error, :unauthorized} = BitmapQueries.run(nil, %{})
    values = TopologyQueryController.values(Plug.Test.conn(:get, "/topology/query/values"), %{"facet" => "vendor"})
    assert values.status == 401
    assert Plug.Conn.get_resp_header(values, "cache-control") == ["no-store"]
    assert {:error, :unauthorized} = BitmapQueries.prefix_tags(%Scope{}, %{"source" => "synthetic"})

    flags = [:god_view_enabled]
    previous = Map.new(flags, &{&1, Application.fetch_env(:serviceradar_web_ng, &1)})
    Enum.each(flags, &Application.put_env(:serviceradar_web_ng, &1, true))

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:serviceradar_web_ng, key, value)
        {key, :error} -> Application.delete_env(:serviceradar_web_ng, key)
      end)
    end)

    budget =
      %Scope{user: %{id: "synthetic-user"}}
      |> then(&Plug.Conn.assign(Plug.Test.conn(:post, "/topology/query"), :current_scope, &1))
      |> TopologyQueryController.create(%{"expression" => String.duplicate("x", 20_000)})

    assert budget.status == 413
    assert Jason.decode!(budget.resp_body) == %{"error" => "query_budget"}
    assert Plug.Conn.get_resp_header(budget, "retry-after") == []
  end

  test "multipart uploads receive HTTP 400 before query admission" do
    flags = [:god_view_enabled]
    previous = Map.new(flags, &{&1, Application.fetch_env(:serviceradar_web_ng, &1)})
    Enum.each(flags, &Application.put_env(:serviceradar_web_ng, &1, true))

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:serviceradar_web_ng, key, value)
        {key, :error} -> Application.delete_env(:serviceradar_web_ng, key)
      end)
    end)

    upload = %Plug.Upload{path: "/unused/synthetic-upload", filename: "example.txt", content_type: "text/plain"}

    for params <- [
          %{"expression" => upload},
          %{"expression" => %{"facet" => "vendor", "value" => upload}},
          %{"expression" => %{"all" => [upload]}},
          %{"cursor" => upload}
        ] do
      conn =
        :post
        |> Plug.Test.conn("/topology/query")
        |> Plug.Conn.assign(:current_scope, %Scope{user: %{id: "synthetic-user"}})
        |> TopologyQueryController.create(params)

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body) == %{"error" => "invalid_query"}
    end
  end

  test "the eight-level parser boundary agrees with native evaluation including EXCEPT wrappers" do
    index = index([{3, true, [{"vendor", "example-a"}]}, {7, true, [{"vendor", "example-b"}]}])

    for {operator, expected} <- [{"all", [3]}, {"except", [7]}] do
      expression =
        Enum.reduce(1..7, predicate("vendor", "example-a"), fn _, child ->
          if operator == "except", do: %{"except" => child}, else: %{"all" => [child]}
        end)

      assert {:ok, parsed} = BitmapExpression.parse(%{"expression" => expression}, @facets)
      assert {:ok, {query, 1, "initial", 1}} = query(index, parsed)
      assert {:ok, ^expected} = Native.bitmap_query_page(query, @authority, 0, 128, 1000)
      Native.bitmap_query_close(query)

      assert {:error, :expression_budget} =
               BitmapExpression.parse(%{"expression" => %{"except" => expression}}, @facets)
    end
  end

  test "a root EXCEPT counts against the complete native program budget" do
    index = index([{3, true, [{"vendor", "example-a"}]}])
    children = Enum.map(1..32, &%{"except" => predicate("vendor", "other-#{&1}")})
    expression = %{"all" => children}
    assert {:ok, parsed} = BitmapExpression.parse(%{"expression" => expression}, @facets)
    assert {:ok, {query, 1, "initial", 1}} = query(index, parsed)
    assert {:ok, [3]} = Native.bitmap_query_page(query, @authority, 0, 128, 1000)
    Native.bitmap_query_close(query)

    assert {:error, :expression_budget} =
             BitmapExpression.parse(%{"expression" => %{"except" => expression}}, @facets)
  end

  # Reproduces the compact scale failure shape: eight sockets' periodic refreshes
  # keep every query task busy when a burst of first watches arrives together.
  test "query admission serves newcomers that arrive while refreshes keep every task busy" do
    start_supervised!(BitmapQueries)
    load = :atomics.new(2, [])
    stop = :atomics.new(1, [])

    refreshers =
      for _ <- 1..8 do
        Task.async(fn -> refresh(fn -> occupy(load, 40) end, stop) end)
      end

    await_running(load, 8)

    newcomers =
      for viewer <- 1..24 do
        Task.async(fn ->
          BitmapQueryAdmission.run(
            fn ->
              occupy(load, 40)
              viewer
            end,
            now() + 1_000
          )
        end)
      end

    results = Task.await_many(newcomers, 5_000)
    :atomics.put(stop, 1, 1)
    Task.await_many(refreshers, 5_000)

    assert results == Enum.map(1..24, &{:ok, &1})
    assert :atomics.get(load, 2) == 8
  end

  test "query admission rejects work it cannot start before the deadline and frees killed slots" do
    start_supervised!(BitmapQueries)
    test = self()

    holders =
      for _ <- 1..8 do
        Task.async(fn ->
          BitmapQueryAdmission.run(
            fn ->
              send(test, :held)
              Process.sleep(:infinity)
            end,
            now() + 600
          )
        end)
      end

    for _ <- 1..8, do: assert_receive(:held, 1_000)
    observe_busy()

    # Sixty-four live waiters fill the queue, so the next request is refused at once.
    waiters =
      for _ <- 1..64, do: Task.async(fn -> BitmapQueryAdmission.run(fn -> send(test, :late_ran) end, now() + 150) end)

    await_waiting(64)
    assert {:error, :query_busy} = BitmapQueryAdmission.run(fn -> send(test, :late_ran) end, now() + 150)
    assert_received {:query_busy, :admission_full}
    assert Task.await_many(waiters, 1_000) == List.duplicate({:error, :query_busy}, 64)
    assert busy_count(:admission_expired) == 64

    # Expired waiters are pruned, so this one queues and then expires unstarted.
    assert {:error, :query_busy} = BitmapQueryAdmission.run(fn -> send(test, :late_ran) end, now() + 100)
    assert busy_count(:admission_expired) == 1
    assert busy_count(:admission_full) == 0

    assert Task.await_many(holders, 2_000) == List.duplicate({:error, :query_timeout}, 8)
    assert {:ok, :admitted} = BitmapQueryAdmission.run(fn -> :admitted end, now() + 500)
    refute_received :late_ran
  end

  defp observe_busy do
    test = self()
    id = make_ref()

    :telemetry.attach(
      id,
      [:serviceradar, :topology, :bitmap_query, :busy],
      fn _event, %{count: 1}, %{source: source}, _config -> send(test, {:query_busy, source}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp busy_count(source, count \\ 0) do
    receive do
      {:query_busy, ^source} -> busy_count(source, count + 1)
    after
      0 -> count
    end
  end

  defp await_waiting(count, attempts \\ 200) do
    waiting = :queue.len(:sys.get_state(BitmapQueryAdmission).waiting)

    cond do
      waiting == count ->
        :ok

      attempts == 0 ->
        flunk("admission never queued #{count} waiters")

      true ->
        Process.sleep(5)
        await_waiting(count, attempts - 1)
    end
  end

  defp refresh(work, stop) do
    if :atomics.get(stop, 1) == 0 do
      BitmapQueryAdmission.run(work, now() + 1_000)
      refresh(work, stop)
    end
  end

  # Slot 1 counts running work and slot 2 keeps its peak.
  defp occupy(load, ms) do
    running = :atomics.add_get(load, 1, 1)
    raise_peak(load, running)
    Process.sleep(ms)
    :atomics.sub(load, 1, 1)
  end

  defp raise_peak(load, running) do
    peak = :atomics.get(load, 2)

    if running > peak and :atomics.compare_exchange(load, 2, peak, running) != :ok do
      raise_peak(load, running)
    end
  end

  defp await_running(load, count, attempts \\ 200) do
    cond do
      :atomics.get(load, 1) == count ->
        :ok

      attempts == 0 ->
        flunk("query tasks never reached #{count} running")

      true ->
        Process.sleep(5)
        await_running(load, count, attempts - 1)
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp index(rows) do
    {:ok, index} = Native.bitmap_index_new(@dictionary, @epoch, :device, @facets)
    on_exit(fn -> Native.bitmap_index_close(index) end)
    {:ok, %{revision: 1}} = Native.bitmap_index_publish(index, 0, "initial", rows, true)
    index
  end

  defp query(index, parsed),
    do: Native.bitmap_index_query(index, @dictionary, @epoch, :device, @authority, parsed.program, 1000)

  defp predicate(facet, value), do: %{"facet" => facet, "value" => value}
end
