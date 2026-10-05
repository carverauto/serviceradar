defmodule ServiceRadar.Analytics.StarRocks.StreamLoadTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks.Attribution
  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.Analytics.StarRocks.LoadAdmission
  alias ServiceRadar.Analytics.StarRocks.LoadSupervisor
  alias ServiceRadar.Analytics.StarRocks.StreamLoad

  @moduletag :db_free

  setup context do
    start_supervised!(
      {LoadSupervisor, max_in_flight: 2, wait_timeout_ms: context[:wait_timeout_ms] || 5_000}
    )

    :ok
  end

  @rows [
    %{"id" => "flow-alpha", "bytes_in" => 1200, "bytes_out" => 80},
    %{"id" => "flow-bravo", "bytes_in" => 44, "bytes_out" => 9}
  ]

  test "a failed coordinator connection retries the same label and payload through the FE" do
    calls = :counters.new(1, [])
    parent = self()

    http = fn request ->
      send(parent, {:request, request})

      if URI.parse(request.url).host == "coordinator.example.com" do
        :counters.add(calls, 1, 1)

        if :counters.get(calls, 1) == 1 do
          {:error, {:connect_failed, :econnrefused}}
        else
          {:ok, %{status: 200, body: %{"Status" => "Success", "NumberLoadedRows" => 2}}}
        end
      else
        {:ok, %{status: 307, headers: [{"location", "http://coordinator.example.com/load"}]}}
      end
    end

    assert {:ok, %{loaded: 2}} = StreamLoad.persist("otel_traces", @rows, http: http)
    assert_received {:request, first_fe}
    assert_received {:request, first_coordinator}
    assert_received {:request, second_fe}
    assert_received {:request, second_coordinator}
    assert first_fe == second_fe
    assert first_coordinator == second_coordinator
    refute_received {:request, _}
  end

  test "persistent connection failures exhaust three attempts and retain the cause" do
    parent = self()

    http = fn request ->
      send(parent, {:request, request})
      {:error, {:connect_failed, :econnrefused}}
    end

    assert {:error, {{:connect_failed, :econnrefused}, label}} =
             StreamLoad.persist("otel_traces", @rows, http: http)

    for _ <- 1..3 do
      assert_received {:request, %{headers: headers}}
      assert {"label", label} in headers
    end

    refute_received {:request, _}
  end

  test "an uncertain commit polls its label without resubmitting a running load" do
    states = :counters.new(1, [])
    parent = self()

    http = fn
      %{method: :put} ->
        send(parent, :put)
        {:error, :timeout}

      %{method: :get} ->
        :counters.add(states, 1, 1)
        state = if :counters.get(states, 1) == 1, do: "PREPARE", else: "VISIBLE"
        {:ok, %{status: 200, body: load_state_body(state)}}
    end

    assert {:ok, %{loaded: 2, reconciled: true}} =
             StreamLoad.persist("otel_traces", @rows, http: http)

    assert_received :put
    refute_received :put
    assert :counters.get(states, 1) == 2
  end

  test "single and split loads from different datasets share admission through redirects" do
    parent = self()

    http = fn request ->
      send(parent, {:request, self(), request})

      receive do
        :redirect ->
          {:ok, %{status: 307, headers: [{"location", "http://cn.example.com/load"}]}}

        :success ->
          {:ok,
           %{
             status: 200,
             body:
               Jason.encode!(%{
                 "Status" => "Success",
                 "NumberLoadedRows" => length(Jason.decode!(request.body)),
                 "NumberFilteredRows" => 0
               })
           }}
      after
        5_000 -> flunk("synthetic HTTP adapter was not released")
      end
    end

    load = fn dataset, rows, options ->
      Task.async(fn ->
        Destination.persist_warehouse(
          dataset,
          rows,
          Keyword.merge([http: http], options)
        )
      end)
    end

    logs =
      load.(:logs, [%{id: "log-first", timestamp: ~U[2000-01-01 00:00:00Z], body: "first"}], [])

    metrics =
      load.(:metrics, [%{timestamp: ~U[2000-01-01 00:00:00Z], metric_name: "cpu", value: 1}], [])

    assert_receive {:request, first, _}, 1_000
    assert_receive {:request, second, _}, 1_000

    split =
      load.(
        :logs,
        [
          %{id: "log-second", timestamp: ~U[2000-01-01 00:00:00Z], body: "second"},
          %{id: "log-third", timestamp: ~U[2000-01-01 00:00:00Z], body: "third"}
        ],
        stream_load: [max_rows: 1]
      )

    refute_receive {:request, _, _}, 100
    send(first, :redirect)
    assert_receive {:request, ^first, %{url: "http://cn.example.com/load"}}, 1_000
    refute_receive {:request, _, _}, 100
    send(first, :success)
    assert_receive {:request, third, _}, 1_000
    refute_receive {:request, _, _}, 100
    send(second, :success)
    assert_receive {:request, fourth, _}, 1_000
    send(third, :success)
    send(fourth, :success)
    assert {:ok, %{loaded: 1}} = Task.await(logs)
    assert {:ok, %{loaded: 1}} = Task.await(metrics)
    assert {:ok, %{loaded: 2, loads: 2}} = Task.await(split)
  end

  @tag wait_timeout_ms: 100
  test "waiting work times out without leaking a late admission, and caller death releases capacity" do
    parent = self()

    http = fn _request ->
      send(parent, {:blocked, self()})

      receive do
        :fail -> {:error, :timeout}
      after
        5_000 -> flunk("synthetic HTTP adapter was not released")
      end
    end

    # Use unlinked callers: killing one simulates cancellation of an in-flight load.
    first = spawn(fn -> StreamLoad.persist("logs", @rows, http: http) end)
    second = spawn(fn -> StreamLoad.persist("otel_metrics", @rows, http: http) end)
    assert_receive {:blocked, _first_worker}
    assert_receive {:blocked, _second_worker}
    max_bytes = Destination.stream_load_limits()[:max_bytes]

    assert {:error, :load_admission_full} =
             LoadAdmission.run(max_bytes * 2 + 1, fn ->
               flunk("over-budget waiter must never start transport work")
             end)

    assert {:error, :load_admission_timeout} =
             StreamLoad.persist("otel_traces", @rows, http: http)

    Process.exit(first, :kill)
    Process.exit(second, :kill)

    successful = fn _ ->
      {:ok,
       %{status: 200, body: ~s({"Status":"Success","NumberLoadedRows":2,"NumberFilteredRows":0})}}
    end

    assert {:ok, %{loaded: 2}} = StreamLoad.persist("logs", @rows, http: successful)
    refute_receive {:blocked, _}, 150
  end

  test "exceptions and transport errors release shared capacity" do
    for _ <- 1..3 do
      assert_raise RuntimeError, "synthetic exception", fn ->
        StreamLoad.persist("logs", @rows, http: fn _ -> raise "synthetic exception" end)
      end

      assert {:error, {:disconnected, _}} =
               StreamLoad.persist("logs", @rows, http: fn _ -> {:error, :disconnected} end)
    end
  end

  test "an admission restart stops outstanding HTTP workers before admitting new loads" do
    parent = self()

    http = fn _ ->
      send(parent, {:active_load, self()})

      receive do
        :unexpected -> flunk("old HTTP worker must be stopped on restart")
      after
        5_000 -> flunk("old HTTP worker survived the admission restart")
      end
    end

    for _ <- 1..2, do: spawn(fn -> StreamLoad.persist("logs", @rows, http: http) end)
    assert_receive {:active_load, first}, 1_000
    assert_receive {:active_load, second}, 1_000
    first_ref = Process.monitor(first)
    second_ref = Process.monitor(second)
    Process.exit(Process.whereis(LoadAdmission), :kill)
    assert_receive {:DOWN, ^first_ref, :process, ^first, _}, 1_000
    assert_receive {:DOWN, ^second_ref, :process, ^second, _}, 1_000
    # A supervisor call completes after its current restart callback finishes.
    assert length(Supervisor.which_children(LoadSupervisor)) == 2

    success = fn _ ->
      {:ok,
       %{status: 200, body: ~s({"Status":"Success","NumberLoadedRows":2,"NumberFilteredRows":0})}}
    end

    assert {:ok, %{loaded: 2}} = StreamLoad.persist("logs", @rows, http: success)
  end

  test "restart during HTTP cancels the load and returns a retryable error" do
    parent = self()

    http = fn _ ->
      send(parent, {:in_flight, self()})
      previous = Process.flag(:trap_exit, true)

      try do
        receive do
          {:EXIT, _pid, reason} ->
            send(parent, :http_cancelled)
            exit(reason)
        after
          5_000 -> flunk("cancelled HTTP worker was not stopped")
        end
      after
        Process.flag(:trap_exit, previous)
      end
    end

    spawn(fn ->
      Process.flag(:trap_exit, true)
      send(parent, {:caller_result, StreamLoad.persist("logs", @rows, http: http)})
    end)

    assert_receive {:in_flight, worker}, 1_000
    worker_ref = Process.monitor(worker)
    Process.exit(Process.whereis(LoadAdmission), :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 1_000
    assert_receive {:caller_result, {:error, :load_admission_unavailable}}, 5_000
    assert length(Supervisor.which_children(LoadSupervisor)) == 2

    success = fn _ ->
      {:ok,
       %{status: 200, body: ~s({"Status":"Success","NumberLoadedRows":2,"NumberFilteredRows":0})}}
    end

    assert {:ok, %{loaded: 2}} = StreamLoad.persist("logs", @rows, http: success)
  end

  test "a cancelled load reports retryable unavailable instead of raising" do
    assert {:error, :load_admission_unavailable} =
             StreamLoad.persist("logs", @rows, http: fn _ -> exit(:shutdown) end)
  end

  test "admission restart window stays on the retry path" do
    Process.exit(Process.whereis(LoadAdmission), :kill)

    results =
      for _ <- 1..20 do
        try do
          LoadAdmission.run(1, fn -> {:ok, :admitted} end)
        catch
          :exit, _ -> :exited
        end
      end

    assert Enum.all?(results, fn
             {:ok, :admitted} -> true
             {:error, :load_admission_unavailable} -> true
             _ -> false
           end)

    assert is_pid(Process.whereis(LoadAdmission))
  end

  test "missing load coordination returns retryable unavailable" do
    :ok = stop_supervised!(LoadSupervisor)

    assert {:error, :load_admission_unavailable} =
             LoadAdmission.run(1, fn -> flunk("work must not start without coordination") end)

    assert {:error, :load_admission_unavailable} =
             StreamLoad.persist("logs", @rows,
               http: fn _ -> flunk("transport must not start without coordination") end
             )
  end

  test "stable identities produce the same load label across retry regrouping" do
    shuffled = Enum.reverse(@rows)

    assert StreamLoad.load_label("ocsf_network_activity", @rows) ==
             StreamLoad.load_label("ocsf_network_activity", shuffled)
  end

  test "HTTP success is not ACK until Status is Success and loaded rows match" do
    http = fn
      %{method: :put, headers: headers, url: url, body: body} ->
        assert url =~ "/api/serviceradar/ocsf_network_activity/_stream_load"
        assert List.keyfind(headers, "label", 0)
        assert Jason.decode!(body) == @rows

        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               "Status" => "Success",
               "NumberLoadedRows" => 2,
               "NumberFilteredRows" => 0
             })
         }}
    end

    assert {:ok, %{loaded: 2, label: label}} =
             StreamLoad.persist("ocsf_network_activity", @rows, http: http, config: %{})

    assert String.starts_with?(label, "sr-")
  end

  test "partial update sets Stream Load headers and does not send traffic columns" do
    rows = [
      %{
        "id" => "flow-alpha-0001",
        "time" => "1999-06-15 12:00:00",
        "attribution_version" => 3,
        "pid" => 9,
        "comm" => "sshd"
      }
    ]

    http = fn %{method: :put, headers: headers, body: body} ->
      assert {"partial_update", "true"} in headers
      assert {"merge_condition", "attribution_version"} in headers
      assert {"columns", Enum.join(Attribution.load_columns(), ",")} in headers
      [payload] = Jason.decode!(body)
      refute Map.has_key?(payload, "bytes_in")
      assert payload["time"] == "1999-06-15 12:00:00"

      {:ok,
       %{
         status: 200,
         body:
           Jason.encode!(%{
             "Status" => "Success",
             "NumberLoadedRows" => 1,
             "NumberFilteredRows" => 0
           })
       }}
    end

    assert {:ok, %{loaded: 1}} =
             StreamLoad.persist("ocsf_network_activity", rows,
               http: http,
               config: %{},
               partial_update: true,
               merge_condition: "attribution_version",
               columns: Attribution.load_columns()
             )
  end

  test "filtered rows quarantine instead of acknowledging" do
    http = fn _request ->
      {:ok,
       %{
         status: 200,
         body:
           Jason.encode!(%{
             "Status" => "Success",
             "NumberLoadedRows" => 1,
             "NumberFilteredRows" => 1
           })
       }}
    end

    assert {:quarantine, {:filtered_rows, 1, _label}} =
             StreamLoad.persist("ocsf_network_activity", @rows, http: http)
  end

  test "publish timeout reconciles the original label before ACK" do
    label = StreamLoad.load_label("ocsf_network_activity", @rows)

    http = fn
      %{method: :put} ->
        {:ok, %{status: 200, body: Jason.encode!(%{"Status" => "Publish Timeout"})}}

      %{method: :get, url: url} ->
        assert url =~ "get_load_state?label=#{label}"

        {:ok, %{status: 200, body: load_state_body("VISIBLE")}}
    end

    assert {:ok, %{loaded: 2, reconciled: true, label: ^label}} =
             StreamLoad.persist("ocsf_network_activity", @rows, http: http, label: label)
  end

  test "redelivery of an already-loaded batch reconciles instead of failing the ACK" do
    label = StreamLoad.load_label("ocsf_network_activity", @rows)

    http = fn
      %{method: :put} ->
        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               "TxnId" => -1,
               "Label" => label,
               "Status" => "Label Already Exists",
               "ExistingJobStatus" => "FINISHED",
               "Message" => "Label [#{label}] has already been used.",
               "NumberTotalRows" => 0,
               "NumberLoadedRows" => 0,
               "NumberFilteredRows" => 0
             })
         }}

      %{method: :get} ->
        {:ok, %{status: 200, body: load_state_body("VISIBLE")}}
    end

    assert {:ok, %{loaded: 2, reconciled: true, label: ^label}} =
             StreamLoad.persist("ocsf_network_activity", @rows, http: http)
  end

  test "a committed but not yet visible transaction is a durable load" do
    http = fn
      %{method: :put} -> {:error, :timeout}
      %{method: :get} -> {:ok, %{status: 200, body: load_state_body("COMMITTED")}}
    end

    assert {:ok, %{loaded: 2, reconciled: true}} =
             StreamLoad.persist("ocsf_network_activity", @rows, http: http)
  end

  test "an aborted label is never acknowledged as persisted" do
    http = fn
      %{method: :put} ->
        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               "Status" => "Label Already Exists",
               "ExistingJobStatus" => "FINISHED"
             })
         }}

      %{method: :get} ->
        {:ok, %{status: 200, body: load_state_body("ABORTED", "too many filtered rows")}}
    end

    assert {:error, {:label_aborted, _label}} =
             StreamLoad.persist("ocsf_network_activity", @rows, http: http)
  end

  test "follows FE 307 redirect to the Stream Load coordinator" do
    parent = self()

    http = fn
      %{url: url} = request ->
        if String.contains?(url, "coordinator") do
          send(parent, {:loaded, url, request.body})

          {:ok,
           %{
             status: 200,
             body:
               Jason.encode!(%{
                 "Status" => "Success",
                 "NumberLoadedRows" => 2,
                 "NumberFilteredRows" => 0
               })
           }}
        else
          send(parent, {:redirected, url})

          {:ok,
           %{
             status: 307,
             headers: [
               {"location",
                "http://coordinator.example.invalid/api/serviceradar/ocsf_network_activity/_stream_load"}
             ],
             body: ""
           }}
        end
    end

    assert {:ok, %{loaded: 2}} =
             StreamLoad.persist("ocsf_network_activity", @rows, http: http, config: %{})

    assert_received {:redirected, fe_url}
    assert fe_url =~ "/_stream_load"

    assert_received {:loaded,
                     "http://coordinator.example.invalid/api/serviceradar/ocsf_network_activity/_stream_load",
                     body}

    assert Jason.decode!(body) == @rows
  end

  test "uninjected persist uses HTTP instead of a stub ACK" do
    assert {:error, {reason, label}} =
             StreamLoad.persist("ocsf_network_activity", @rows,
               config: %{fe_http: "http://127.0.0.1:1", database: "serviceradar"}
             )

    refute reason == :starrocks_http_not_configured
    assert is_binary(label)
    assert String.starts_with?(label, "sr-")
  end

  test "the real HTTP adapter does not hide extra Retry-After attempts" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin, reuseaddr: true])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()

    start_supervised!(
      {Task,
       fn ->
         for _ <- 1..3 do
           {:ok, socket} = :gen_tcp.accept(listener, 3_000)
           {:ok, {:http_request, :PUT, _, _}} = :gen_tcp.recv(socket, 0, 3_000)
           headers = receive_headers(socket, %{})
           :ok = :gen_tcp.send(socket, "HTTP/1.1 100 Continue\r\n\r\n")
           :ok = :inet.setopts(socket, packet: :raw)

           {:ok, body} =
             :gen_tcp.recv(socket, String.to_integer(headers["content-length"]), 3_000)

           send(parent, {:wire_request, headers["label"], Jason.decode!(body)})

           :ok =
             :gen_tcp.send(
               socket,
               "HTTP/1.1 503 Service Unavailable\r\nRetry-After: 0\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
             )

           :gen_tcp.close(socket)
         end
       end}
    )

    assert {:error, {:http_status, 503, label}} =
             StreamLoad.persist("otel_traces", @rows,
               config: %{fe_http: "http://127.0.0.1:#{port}"},
               http_timeout: 3_000
             )

    for _ <- 1..3 do
      assert_received {:wire_request, ^label, @rows}
    end

    refute_received {:wire_request, _, _}
  end

  defp receive_headers(socket, headers) do
    case :gen_tcp.recv(socket, 0, 3_000) do
      {:ok, :http_eoh} ->
        headers

      {:ok, {:http_header, _, key, _, value}} ->
        receive_headers(socket, Map.put(headers, key |> to_string() |> String.downcase(), value))
    end
  end

  test "lost HTTP response after timeout does not ACK until the transaction commits" do
    http = fn
      %{method: :put} -> {:error, :timeout}
      %{method: :get} -> {:ok, %{status: 200, body: load_state_body("UNKNOWN")}}
    end

    assert {:error, {:unresolved_label, _label, "ocsf_network_activity"}} =
             StreamLoad.persist("ocsf_network_activity", @rows, http: http)
  end

  # Shape of a real `/api/<db>/get_load_state` answer, as returned by the
  # StarRocks release this change targets.
  defp load_state_body(state, reason \\ "") do
    Jason.encode!(%{
      "state" => state,
      "reason" => reason,
      "status" => "OK",
      "code" => "0",
      "msg" => "Success",
      "message" => "OK"
    })
  end
end
