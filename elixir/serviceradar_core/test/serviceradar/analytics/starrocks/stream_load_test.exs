defmodule ServiceRadar.Analytics.StarRocks.StreamLoadTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Analytics.StarRocks.Attribution
  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.Analytics.StarRocks.LoadAdmission
  alias ServiceRadar.Analytics.StarRocks.LoadSupervisor
  alias ServiceRadar.Analytics.StarRocks.LoadTasks
  alias ServiceRadar.Analytics.StarRocks.StreamLoad

  @moduletag :db_free

  setup context do
    workers = if context[:workers], do: [workers: context[:workers]], else: []

    start_supervised!(
      {LoadSupervisor,
       [
         max_in_flight: context[:max_in_flight] || 2,
         wait_timeout_ms: context[:wait_timeout_ms] || 5_000
       ] ++ workers}
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

  test "transient compute-node transport Fail messages retry with the same label at warning while unrelated Fail messages do not" do
    transient_messages = [
      "Couldn't open transport for :0 (Could not resolve host for client socket.)",
      "[E104]Fail to read from Socket"
    ]

    for message <- transient_messages do
      calls = :counters.new(1, [])
      parent = self()

      http = fn %{headers: headers} ->
        :counters.add(calls, 1, 1)
        send(parent, {:attempt_label, header_value(headers, "label")})

        body =
          if :counters.get(calls, 1) == 1 do
            Jason.encode!(%{"Status" => "Fail", "Message" => message})
          else
            Jason.encode!(%{
              "Status" => "Success",
              "NumberLoadedRows" => 2,
              "NumberFilteredRows" => 0
            })
          end

        {:ok, %{status: 200, body: body}}
      end

      log =
        capture_log(fn ->
          assert {:ok, %{loaded: 2, label: persisted_label}} =
                   StreamLoad.persist("otel_traces", @rows, http: http)

          assert_received {:attempt_label, ^persisted_label}
          assert_received {:attempt_label, ^persisted_label}
          refute_received {:attempt_label, _}
        end)

      assert :counters.get(calls, 1) == 2
      assert log =~ "[warning]"
      assert log =~ "StarRocks Stream Load attempt failed"
      assert log =~ message
      refute log =~ "[error]"
    end

    unrelated_calls = :counters.new(1, [])

    unrelated_http = fn _request ->
      :counters.add(unrelated_calls, 1, 1)

      {:ok,
       %{
         status: 200,
         body: Jason.encode!(%{"Status" => "Fail", "Message" => "too many filtered rows"})
       }}
    end

    assert {:error, {:load_status, "Fail", "too many filtered rows", _label}} =
             StreamLoad.persist("otel_traces", @rows, http: unrelated_http)

    assert :counters.get(unrelated_calls, 1) == 1
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

  test "a load that timed out before its transaction began is loaded again under the same label" do
    parent = self()
    puts = :counters.new(1, [])

    http = fn
      %{method: :put} = request ->
        :counters.add(puts, 1, 1)
        send(parent, {:put, List.keyfind(request.headers, "label", 0)})

        if :counters.get(puts, 1) == 1 do
          {:error, :timeout}
        else
          {:ok,
           %{
             status: 200,
             body: ~s({"Status":"Success","NumberLoadedRows":2,"NumberFilteredRows":0})
           }}
        end

      # The FE has no transaction for the label: the timed-out attempt never
      # began one, so nothing was persisted under it.
      %{method: :get} ->
        {:ok, %{status: 200, body: load_state_body("UNKNOWN")}}
    end

    log =
      capture_log(fn ->
        assert {:ok, %{loaded: 2}} = StreamLoad.persist("otel_metrics", @rows, http: http)
      end)

    assert_received {:put, {"label", label}}
    assert_received {:put, {"label", ^label}}
    assert :counters.get(puts, 1) == 2
    assert log =~ "trigger=:http_timeout state_answer={:ok, \"UNKNOWN\"}"
  end

  # Bounded poll for an expected eventual condition (supervisor restart).
  # Returns true when fun yields a pid within timeout_ms, false otherwise.
  defp eventually(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_until(fun, deadline)
  end

  defp poll_until(fun, deadline) do
    case fun.() do
      pid when is_pid(pid) ->
        true

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          poll_until(fun, deadline)
        else
          false
        end
    end
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

  # Every core replica runs EventWriter workers, so max_in_flight is the
  # deployment's budget: three replicas sharing four loads admit one each. The
  # waiting queue still holds the whole budget's callers, so the extra callers
  # wait instead of failing back to JetStream.
  @tag max_in_flight: 4
  @tag workers: 3
  test "worker replicas split max_in_flight and keep the full waiting queue" do
    parent = self()

    callers =
      for n <- 1..4 do
        Task.async(fn ->
          LoadAdmission.run(1, fn ->
            send(parent, {:admitted, n, self()})

            receive do
              :release -> {:ok, n}
            after
              5_000 -> flunk("synthetic load was not released")
            end
          end)
        end)
      end

    for _ <- 1..4 do
      assert_receive {:admitted, _n, worker}, 1_000
      refute_receive {:admitted, _, _}, 100
      send(worker, :release)
    end

    assert callers |> Task.await_many() |> Enum.sort() == Enum.map(1..4, &{:ok, &1})
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

    # Models the default HTTP adapter: traps the supervisor shutdown, cancels
    # the physical request, then exits with the shutdown reason.
    cancelling_http = fn _ ->
      send(parent, {:in_flight_cancelling, self()})
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

    # A worker that cannot trap the shutdown dies with it. Its caller must
    # still observe the retryable error: the admitted worker is unlinked, so
    # the shutdown never propagates through a link to the caller.
    blocking_http = fn _ ->
      send(parent, {:in_flight_blocking, self()})

      receive do
        :unexpected -> flunk("old HTTP worker must be stopped on restart")
      after
        5_000 -> flunk("old HTTP worker survived the admission restart")
      end
    end

    # Normal callers: trap_exit stays false, so a linked supervisor shutdown
    # would kill them instead of returning the retryable error below.
    cancelling_caller =
      spawn(fn ->
        send(
          parent,
          {:caller_result, StreamLoad.persist("logs", @rows, http: cancelling_http)}
        )
      end)

    blocking_caller =
      spawn(fn ->
        send(
          parent,
          {:blocking_result, StreamLoad.persist("logs", @rows, http: blocking_http)}
        )
      end)

    cancelling_ref = Process.monitor(cancelling_caller)
    blocking_ref = Process.monitor(blocking_caller)
    assert_receive {:in_flight_cancelling, _cancelling_worker}, 1_000
    assert_receive {:in_flight_blocking, blocking_worker}, 1_000
    blocking_worker_ref = Process.monitor(blocking_worker)
    Process.exit(Process.whereis(LoadAdmission), :kill)
    assert_receive {:DOWN, ^blocking_worker_ref, :process, ^blocking_worker, _}, 1_000
    # Physical HTTP cancellation runs before the retryable result is reported.
    assert_receive :http_cancelled, 1_000
    assert_receive {:caller_result, {:error, :load_admission_unavailable}}, 5_000
    assert_receive {:blocking_result, {:error, :load_admission_unavailable}}, 5_000
    # Both normal callers survived the supervisor restart instead of exiting.
    assert_receive {:DOWN, ^cancelling_ref, :process, ^cancelling_caller, :normal}, 1_000
    assert_receive {:DOWN, ^blocking_ref, :process, ^blocking_caller, :normal}, 1_000
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

  test "stopping-node exits and load path do not call ensure_all_started or crash the caller" do
    assert {:error, :load_admission_unavailable} =
             StreamLoad.persist("logs", @rows, http: fn _ -> exit(:terminating) end)

    assert {:error, :load_admission_unavailable} =
             StreamLoad.persist("logs", @rows,
               http: fn _ -> exit({:terminating, :application_controller}) end
             )

    assert {:error, :load_admission_unavailable} =
             StreamLoad.persist("logs", @rows, http: fn _ -> {:error, :terminating} end)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin, reuseaddr: true])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()
    label = StreamLoad.load_label("otel_traces", @rows)

    start_supervised!({Task, fn -> serve_publish_timeout_then_state(listener, parent) end})

    :erlang.trace(:new_processes, true, [:call, {:tracer, parent}])
    :erlang.trace_pattern({Application, :ensure_all_started, :_}, true, [:global])

    on_exit(fn ->
      :erlang.trace(:new_processes, false, [:call])
      :erlang.trace_pattern({Application, :ensure_all_started, :_}, false, [:global])
    end)

    assert {:ok, %{loaded: 2, reconciled: true, label: ^label}} =
             StreamLoad.persist("otel_traces", @rows,
               config: %{fe_http: "http://127.0.0.1:#{port}"},
               label: label,
               http_timeout: 8_000
             )

    refute_received {:trace, _pid, :call, {Application, :ensure_all_started, _args}}
  end

  test "unrelated callback exits are re-raised instead of retried" do
    assert catch_exit(StreamLoad.persist("logs", @rows, http: fn _ -> exit(:my_bug) end)) ==
             :my_bug

    success = fn _ ->
      {:ok,
       %{status: 200, body: ~s({"Status":"Success","NumberLoadedRows":2,"NumberFilteredRows":0})}}
    end

    assert {:ok, %{loaded: 2}} = StreamLoad.persist("logs", @rows, http: success)
  end

  test "immediate caller death never leaks workers or permits" do
    parent = self()

    for i <- 1..25 do
      tag = {:leak_probe, i}

      http = fn _ ->
        send(parent, {tag, self()})

        receive do
          :unexpected -> flunk("worker survived caller death")
        after
          5_000 -> flunk("worker survived caller death")
        end
      end

      caller = spawn(fn -> StreamLoad.persist("logs", @rows, http: http) end)
      Process.exit(caller, :kill)

      receive do
        {^tag, worker} ->
          ref = Process.monitor(worker)
          assert_receive {:DOWN, ^ref, :process, ^worker, _}, 2_000
      after
        0 -> :no_worker_started
      end
    end

    drain_leak_probes()

    success = fn _ ->
      {:ok,
       %{status: 200, body: ~s({"Status":"Success","NumberLoadedRows":2,"NumberFilteredRows":0})}}
    end

    assert {:ok, %{loaded: 2}} = StreamLoad.persist("logs", @rows, http: success)
  end

  @tag max_in_flight: 1
  test "caller death escalates when the worker ignores shutdown" do
    parent = self()

    ignoring_http = fn _request ->
      send(parent, {:ignoring_worker, self()})
      Process.flag(:trap_exit, true)
      send(parent, :ignoring_trapping)

      receive do
        {:EXIT, _pid, :shutdown} -> send(parent, :shutdown_ignored)
      after
        2_000 -> flunk("watcher never attempted catchable shutdown")
      end

      receive do
        :release -> flunk("escalated worker must not resume")
      after
        30_000 -> flunk("escalation never killed the worker")
      end
    end

    caller = spawn(fn -> StreamLoad.persist("logs", @rows, http: ignoring_http) end)
    assert_receive {:ignoring_worker, worker}, 1_000
    assert_receive :ignoring_trapping, 1_000
    ref = Process.monitor(worker)
    Process.exit(caller, :kill)
    assert_receive :shutdown_ignored, 2_000
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 8_000

    success = fn _ ->
      {:ok,
       %{status: 200, body: ~s({"Status":"Success","NumberLoadedRows":2,"NumberFilteredRows":0})}}
    end

    assert {:ok, %{loaded: 2}} = StreamLoad.persist("logs", @rows, http: success)
  end

  test "killing the caller closes the real HTTP request and frees the permit" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin, reuseaddr: true])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()

    start_supervised!({Task, fn -> serve_cancellable_loads(listener, parent) end})

    config = %{fe_http: "http://127.0.0.1:#{port}"}
    caller = spawn(fn -> StreamLoad.persist("logs", @rows, config: config) end)
    assert_receive {:wire_request, @rows}, 5_000
    assert [worker] = Task.Supervisor.children(LoadTasks)
    worker_ref = Process.monitor(worker)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 3_000
    assert_receive {:peer_result, {:error, :closed}}, 3_000

    assert {:ok, %{loaded: 2}} = StreamLoad.persist("logs", @rows, config: config)
    assert_received {:wire_request, @rows}
  end

  test "admission restart closes the real HTTP request and keeps the caller retryable" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin, reuseaddr: true])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()

    start_supervised!({Task, fn -> serve_cancellable_loads(listener, parent) end})

    config = %{fe_http: "http://127.0.0.1:#{port}"}

    spawn(fn ->
      send(parent, {:caller_result, StreamLoad.persist("logs", @rows, config: config)})
    end)

    assert_receive {:wire_request, @rows}, 5_000
    assert [worker] = Task.Supervisor.children(LoadTasks)
    worker_ref = Process.monitor(worker)
    Process.exit(Process.whereis(LoadAdmission), :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 3_000
    assert_receive {:peer_result, {:error, :closed}}, 3_000
    assert_receive {:caller_result, {:error, :load_admission_unavailable}}, 5_000
    assert length(Supervisor.which_children(LoadSupervisor)) == 2

    assert {:ok, %{loaded: 2}} = StreamLoad.persist("logs", @rows, config: config)
    assert_received {:wire_request, @rows}
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

    # Supervisor restart is asynchronous; poll briefly rather than asserting
    # it completed within microseconds of the kill.
    assert eventually(fn -> Process.whereis(LoadAdmission) end, 2_000)
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

  test "ordinary load labels distinguish content while ignoring encode-time stamps" do
    row = %{"id" => "synthetic-event", "time" => "2026-01-15T10:00:00Z", "message" => "first"}
    label = StreamLoad.load_label("events", [row])

    for changed <- [
          Map.put(row, "time", "2026-01-15T11:00:00Z"),
          Map.put(row, "message", "resolved")
        ] do
      refute StreamLoad.load_label("events", [changed]) == label
    end

    assert StreamLoad.load_label("events", [Map.put(row, "created_at", "2026-01-16T10:00:00Z")]) ==
             label
  end

  test "interleaved replacement redelivery restores the delivered event" do
    first = %{
      "id" => "00000000-0000-4000-8000-000000000001",
      "time" => "2026-01-15T10:00:00Z",
      "log_provider" => "trivy",
      "message" => "first"
    }

    second = %{
      "id" => "00000000-0000-4000-8000-000000000001",
      "time" => "2026-01-15T11:00:00Z",
      "log_provider" => "trivy",
      "message" => "rescan"
    }

    parent = self()
    loaded_labels = :ets.new(:loaded_labels, [:set, :public])

    warehouse = :ets.new(:warehouse, [:set, :public])

    http = fn
      %{method: :put, headers: headers, body: body} ->
        {"label", label} = List.keyfind(headers, "label", 0)

        if :ets.member(loaded_labels, label) do
          {:ok,
           %{
             status: 200,
             body:
               Jason.encode!(%{
                 "Status" => "Label Already Exists",
                 "Message" => "Label [#{label}] has already been used."
               })
           }}
        else
          :ets.insert(loaded_labels, {label})
          rows = Jason.decode!(body)

          for row <- rows do
            :ets.insert(warehouse, {{row["id"], row["time"]}, row})
          end

          send(parent, {:loaded, label, rows})

          {:error, :timeout}
        end

      %{method: :get, url: url} ->
        label =
          url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("label")

        assert :ets.member(loaded_labels, label)
        send(parent, {:reconciled, label})
        {:ok, %{status: 200, body: load_state_body("VISIBLE")}}
    end

    delete = fn sql ->
      protected =
        ~r/\(id = '([^']+)' AND time = '([^']+)'\)/
        |> Regex.scan(sql)
        |> Enum.map(fn [_, id, time] -> {id, NaiveDateTime.from_iso8601!(time)} end)

      for {{id, time} = key, _row} <- :ets.tab2list(warehouse),
          {id, NaiveDateTime.from_iso8601!(time)} not in protected do
        :ets.delete(warehouse, key)
      end

      {:ok, %{}}
    end

    opts = [
      http: http,
      delete: delete,
      replace: %{ids: [first["id"]], log_provider: "trivy"},
      completed: [:cnpg],
      require_all: true
    ]

    assert {:ok, %{loaded: 1}} = Destination.persist_shadow(:events, [first], opts)
    assert_received {:loaded, first_label, [_]}
    assert_received {:reconciled, ^first_label}

    assert {:ok, %{loaded: 1}} = Destination.persist_shadow(:events, [second], opts)
    assert_received {:loaded, second_label, [replacement]}
    refute first_label == second_label
    assert :ets.tab2list(warehouse) == [{{second["id"], second["time"]}, replacement}]

    assert {:ok, %{loaded: 1}} = Destination.persist_shadow(:events, [first], opts)
    assert_received {:loaded, restored_label, [restored]}
    assert_received {:reconciled, ^restored_label}
    refute restored_label == first_label
    assert restored["message"] == "first"
    assert :ets.tab2list(warehouse) == [{{first["id"], first["time"]}, restored}]

    assert {:ok, %{loaded: 1}} = Destination.persist_shadow(:events, [second], opts)
    assert_received {:loaded, replay_label, [replayed]}
    refute replay_label == second_label
    assert :ets.tab2list(warehouse) == [{{second["id"], second["time"]}, replayed}]

    updated = Map.put(second, "message", "resolved")
    assert {:ok, %{loaded: 1}} = Destination.persist_shadow(:events, [updated], opts)
    assert_received {:loaded, updated_label, [latest]}
    refute updated_label == second_label
    assert latest["message"] == "resolved"

    assert {:ok, %{loaded: 1}} = Destination.persist_shadow(:events, [updated], opts)
    assert_received {:loaded, replay_label, [replayed]}
    refute replay_label == updated_label
    assert :ets.tab2list(warehouse) == [{{second["id"], second["time"]}, replayed}]
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

  # Two loaders of one batch share its content-hash label. The loser is told
  # the label is used while the winner's transaction is still running; it must
  # wait for that outcome rather than fail a load that is about to land.
  test "a label already used by a load still in flight is awaited until it commits" do
    parent = self()
    polls = :counters.new(1, [])

    http = fn
      %{method: :put} ->
        send(parent, :put)
        {:ok, %{status: 200, body: Jason.encode!(%{"Status" => "Label Already Exists"})}}

      %{method: :get} ->
        :counters.add(polls, 1, 1)

        state =
          case :counters.get(polls, 1) do
            n when n <= 2 -> "PREPARE"
            n when n <= 4 -> "PREPARED"
            _ -> "VISIBLE"
          end

        {:ok, %{status: 200, body: load_state_body(state)}}
    end

    assert {:ok, %{loaded: 2, reconciled: true}} =
             StreamLoad.persist("timeseries_metrics", @rows, http: http)

    assert :counters.get(polls, 1) == 5
    assert_received :put
    refute_received :put
  end

  test "a label that stays in flight past the load budget fails inside that budget" do
    http = fn
      %{method: :put} ->
        {:ok, %{status: 200, body: Jason.encode!(%{"Status" => "Label Already Exists"})}}

      %{method: :get} ->
        {:ok, %{status: 200, body: load_state_body("PREPARED")}}
    end

    started = System.monotonic_time(:millisecond)

    assert {:error, {:unresolved_label, _label, "timeseries_metrics"}} =
             StreamLoad.persist("timeseries_metrics", @rows, http: http, http_timeout: 1_000)

    assert System.monotonic_time(:millisecond) - started < 2_000
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

  test "reconciles when StarRocks returns Status Fail with label already used message" do
    label = StreamLoad.load_label("ocsf_network_activity", @rows)

    http = fn
      %{method: :put} ->
        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               "Status" => "Fail",
               "Message" => "Label [#{label}] has already been used."
             })
         }}

      %{method: :get} ->
        {:ok, %{status: 200, body: load_state_body("VISIBLE")}}
    end

    assert {:ok, %{loaded: 2, reconciled: true, label: ^label}} =
             StreamLoad.persist("ocsf_network_activity", @rows, http: http)
  end

  test "reconciles when StarRocks returns Status LABEL_ALREADY_EXISTS" do
    label = StreamLoad.load_label("ocsf_network_activity", @rows)

    http = fn
      %{method: :put} ->
        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               "Status" => "LABEL_ALREADY_EXISTS",
               "Message" => "Label [#{label}] has already been used."
             })
         }}

      %{method: :get} ->
        {:ok, %{status: 200, body: load_state_body("VISIBLE")}}
    end

    assert {:ok, %{loaded: 2, reconciled: true, label: ^label}} =
             StreamLoad.persist("ocsf_network_activity", @rows, http: http)
  end

  test "a follower's 307 to the FE leader is followed when reconciling the label state" do
    label = StreamLoad.load_label("ocsf_network_activity", @rows)
    parent = self()

    http = fn
      %{method: :put} ->
        {:ok, %{status: 200, body: Jason.encode!(%{"Status" => "Label Already Exists"})}}

      %{method: :get, url: url} ->
        cond do
          String.contains?(url, "follower-fe") ->
            send(parent, {:follower_queried, url})

            {:ok,
             %{
               status: 307,
               headers: [{"location", "http://leader-fe:8030#{state_path(label)}"}],
               body: ""
             }}

          String.contains?(url, "leader-fe") ->
            send(parent, {:leader_queried, url})
            {:ok, %{status: 200, body: load_state_body("VISIBLE")}}

          true ->
            flunk("unexpected state request to #{url}")
        end
    end

    assert {:ok, %{loaded: 2, reconciled: true, label: ^label}} =
             StreamLoad.persist("ocsf_network_activity", @rows,
               http: http,
               label: label,
               config: %{fe_http: "http://follower-fe:8030", database: "serviceradar"}
             )

    assert_received {:follower_queried, _}
    assert_received {:leader_queried, url}
    assert url =~ "leader-fe:8030/api/serviceradar/get_load_state?label=#{label}"
  end

  test "a state redirect off the FE port is not followed" do
    label = StreamLoad.load_label("ocsf_network_activity", @rows)
    parent = self()

    http = fn
      %{method: :put} ->
        {:ok, %{status: 200, body: Jason.encode!(%{"Status" => "Label Already Exists"})}}

      %{method: :get, url: url} ->
        send(parent, {:state_request, url})

        {:ok,
         %{
           status: 307,
           headers: [{"location", "http://elsewhere.example.com:9990#{state_path(label)}"}],
           body: ""
         }}
    end

    # Every reconcile attempt lands on the configured FE and refuses the
    # off-port redirect: the load stays unresolved (bounded retries, then the
    # caller's NAK path) instead of steered anywhere with credentials.
    assert {:error, {:unresolved_label, ^label, "ocsf_network_activity"}} =
             StreamLoad.persist("ocsf_network_activity", @rows,
               http: http,
               label: label,
               config: %{fe_http: "http://follower-fe:8030", database: "serviceradar"},
               http_timeout: 50
             )

    assert_received {:state_request, _}
  end

  test "an aborted label retries the load under a disambiguated label" do
    parent = self()

    http = fn
      %{method: :put, headers: headers} = request ->
        label = header_value(headers, "label")
        send(parent, {:load_attempt, label})

        if String.contains?(label, "-a") do
          {:ok,
           %{
             status: 200,
             body:
               Jason.encode!(%{
                 "Status" => "Success",
                 "Label" => label,
                 "NumberLoadedRows" => 2,
                 "NumberFilteredRows" => 0
               })
           }}
        else
          {:ok, %{status: 200, body: Jason.encode!(%{"Status" => "Label Already Exists"})}}
        end

      %{method: :get} ->
        {:ok, %{status: 200, body: load_state_body("ABORTED")}}
    end

    assert {:ok, %{loaded: 2}} =
             StreamLoad.persist("ocsf_network_activity", @rows, http: http)

    assert_received {:load_attempt, first}
    assert_received {:load_attempt, retry}
    assert retry == "#{first}-a2"
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

    assert {:connect_failed, _cause} = reason
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

  test "a load the coordinator rejects before reading its body does not poison the next load" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin, reuseaddr: true])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    start_supervised!({Task, fn -> serve_early_rejection_then_success(listener) end})
    config = %{fe_http: "http://127.0.0.1:#{port}"}

    assert {:error, {:load_status, "Fail", "rejected from headers", _label}} =
             StreamLoad.persist("otel_traces", @rows, config: config, http_timeout: 3_000)

    assert {:ok, %{loaded: 2}} =
             StreamLoad.persist("otel_traces", @rows, config: config, http_timeout: 3_000)
  end

  # The StarRocks FE answers a Stream Load with a 307 from its headers alone and
  # closes the connection without reading the body. A client that writes the
  # body anyway races that close: once the body outgrows the socket buffers the
  # redirect is lost to a reset socket, and large loads failed with
  # `{:connect_failed, :closed}` on every attempt. The body must wait for the
  # server to ask for it.
  test "a load sends no body to the FE and follows its redirect sent from the headers" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin, reuseaddr: true])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()

    start_supervised!({Task, fn -> serve_header_redirecting_fe(listener, parent, port) end})

    pad = String.duplicate("x", 1_000_000)
    rows = [%{"id" => "flow-alpha", "pad" => pad}, %{"id" => "flow-bravo", "pad" => pad}]

    assert {:ok, %{loaded: 2}} =
             StreamLoad.persist("otel_traces", rows,
               config: %{fe_http: "http://127.0.0.1:#{port}"},
               http_timeout: 10_000
             )

    assert_received {:wire_request, ["flow-alpha", "flow-bravo"]}
    assert_received {:fe_early_body_bytes, 0}
    refute_received {:fe_early_body_bytes, _}
  end

  # RFC 9110 lets the client send the body when 100 Continue never arrives.
  # The body must still wait out that interval: writing it immediately is the
  # race this transport exists to avoid, and giving up when no 100 arrives
  # would drop loads against a coordinator that only reads the body.
  test "a silent server receives the body only after the continue wait" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin, reuseaddr: true])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()

    start_supervised!({Task, fn -> serve_silent_then_body(listener, parent) end})

    assert {:ok, %{loaded: 2}} =
             StreamLoad.persist("otel_traces", @rows,
               config: %{fe_http: "http://127.0.0.1:#{port}"},
               http_timeout: 10_000
             )

    assert_received {:early_body_bytes, 0}
    assert_received {:wire_request, ["flow-alpha", "flow-bravo"]}
  end

  # Label-state polls have no body, so they stay on Req. A publish-timeout
  # answer from the headers must not be followed by a second load, and the
  # poll itself must not advertise Expect or a body.
  test "a header-only publish timeout is reconciled by a body-less state poll" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin, reuseaddr: true])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()
    label = StreamLoad.load_label("otel_traces", @rows)

    start_supervised!({Task, fn -> serve_publish_timeout_then_state(listener, parent) end})

    assert {:ok, %{loaded: 2, reconciled: true, label: ^label}} =
             StreamLoad.persist("otel_traces", @rows,
               config: %{fe_http: "http://127.0.0.1:#{port}"},
               label: label,
               http_timeout: 8_000
             )

    assert_received {:load_early_body_bytes, 0}
    assert_received {:state_poll, :get, path, headers}
    assert path =~ "/api/serviceradar/get_load_state?label=#{label}"
    refute Map.has_key?(headers, "expect")
    refute Map.has_key?(headers, "content-length")
    refute_received {:load_early_body_bytes, _}
    refute_received {:state_poll, _, _, _}
  end

  test "a coordinator 400 is terminal and is not retried on the wire" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin, reuseaddr: true])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()

    start_supervised!(
      {Task,
       fn ->
         {:ok, socket} = :gen_tcp.accept(listener, 3_000)
         {:ok, {:http_request, :PUT, _, _}} = :gen_tcp.recv(socket, 0, 3_000)
         _headers = receive_headers(socket, %{})

         :ok =
           :gen_tcp.send(
             socket,
             "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
           )

         :gen_tcp.close(socket)
         send(parent, :saw_400)

         case :gen_tcp.accept(listener, 1_000) do
           {:ok, retry} ->
             send(parent, :retried)
             :gen_tcp.close(retry)

           {:error, :timeout} ->
             send(parent, :no_retry)
         end
       end}
    )

    assert {:error, {:http_status, 400, _label}} =
             StreamLoad.persist("otel_traces", @rows,
               config: %{fe_http: "http://127.0.0.1:#{port}"},
               http_timeout: 4_000
             )

    assert_receive :saw_400
    assert_receive :no_retry, 2_000
    refute_received :retried
  end

  defp drain_leak_probes do
    receive do
      {{:leak_probe, _}, worker} ->
        ref = Process.monitor(worker)
        assert_receive {:DOWN, ^ref, :process, ^worker, _}, 2_000
        drain_leak_probes()
    after
      0 -> :done
    end
  end

  defp serve_cancellable_loads(listener, parent) do
    case :gen_tcp.accept(listener, 5_000) do
      {:ok, socket} ->
        read_wire_request(socket, parent)
        send(parent, {:peer_result, :gen_tcp.recv(socket, 0, 10_000)})
        :gen_tcp.close(socket)
        serve_success_loads(listener, parent)

      {:error, :closed} ->
        :ok

      {:error, :timeout} ->
        serve_cancellable_loads(listener, parent)
    end
  end

  defp serve_success_loads(listener, parent) do
    case :gen_tcp.accept(listener, 5_000) do
      {:ok, socket} ->
        rows = read_wire_request(socket, parent)

        response =
          Jason.encode!(%{
            "Status" => "Success",
            "NumberLoadedRows" => length(rows),
            "NumberFilteredRows" => 0
          })

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ",
            Integer.to_string(byte_size(response)),
            "\r\n\r\n",
            response
          ])

        :gen_tcp.close(socket)
        serve_success_loads(listener, parent)

      {:error, :closed} ->
        :ok

      {:error, :timeout} ->
        serve_success_loads(listener, parent)
    end
  end

  # Models the StarRocks BE HTTP server: it can answer a Stream Load from its
  # headers alone without consuming the body. On a kept-alive socket the unread
  # body then corrupts the request parser, so the next request sent on that
  # socket is answered with a bare 400. A client `Connection: close` is honoured.
  defp serve_early_rejection_then_success(listener) do
    {:ok, socket} = :gen_tcp.accept(listener, 3_000)
    {:ok, {:http_request, :PUT, _, _}} = :gen_tcp.recv(socket, 0, 3_000)
    headers = receive_headers(socket, %{})
    close? = String.downcase(headers["connection"] || "") == "close"
    response = Jason.encode!(%{"Status" => "Fail", "Message" => "rejected from headers"})

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n",
        if(close?, do: "Connection: close\r\n", else: ""),
        "Content-Length: #{byte_size(response)}\r\n\r\n",
        response
      ])

    if close? do
      :gen_tcp.close(socket)
      serve_success_loads(listener, self())
    else
      :ok = :inet.setopts(socket, packet: :raw)
      {:ok, _unread_body} = :gen_tcp.recv(socket, String.to_integer(headers["content-length"]))
      {:ok, _next_request} = :gen_tcp.recv(socket, 0, 3_000)
      :ok = :gen_tcp.send(socket, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
      :gen_tcp.close(socket)
    end
  end

  # Models the StarRocks FE: every load to the FE path is redirected from its
  # headers alone and the connection closed with the body unread. Loads to the
  # redirect target are answered like a coordinator.
  defp serve_header_redirecting_fe(listener, parent, port) do
    case :gen_tcp.accept(listener, 5_000) do
      {:ok, socket} ->
        {:ok, {:http_request, :PUT, {:abs_path, path}, _}} = :gen_tcp.recv(socket, 0, 5_000)
        headers = receive_headers(socket, %{})

        if String.starts_with?(path, "/coordinator") do
          :ok = :gen_tcp.send(socket, "HTTP/1.1 100 Continue\r\n\r\n")
          :ok = :inet.setopts(socket, packet: :raw)
          {:ok, body} = :gen_tcp.recv(socket, String.to_integer(headers["content-length"]), 5_000)
          rows = Jason.decode!(body)
          send(parent, {:wire_request, Enum.map(rows, & &1["id"])})

          response =
            Jason.encode!(%{
              "Status" => "Success",
              "NumberLoadedRows" => length(rows),
              "NumberFilteredRows" => 0
            })

          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ",
              Integer.to_string(byte_size(response)),
              "\r\n\r\n",
              response
            ])
        else
          # Whatever body arrives before the FE has answered was sent without
          # being asked for; the real FE never reads it.
          :ok = :inet.setopts(socket, packet: :raw)

          early_bytes =
            case :gen_tcp.recv(socket, 0, 300) do
              {:ok, data} -> byte_size(data)
              {:error, _timeout_or_closed} -> 0
            end

          send(parent, {:fe_early_body_bytes, early_bytes})

          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:#{port}/coordinator",
              path,
              "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            ])
        end

        :gen_tcp.close(socket)
        serve_header_redirecting_fe(listener, parent, port)

      {:error, :closed} ->
        :ok

      {:error, :timeout} ->
        serve_header_redirecting_fe(listener, parent, port)
    end
  end

  # Reads headers, proves nothing arrived during the continue wait, then
  # reads the body the client sends on its own and acknowledges the load.
  defp serve_silent_then_body(listener, parent) do
    {:ok, socket} = :gen_tcp.accept(listener, 5_000)
    {:ok, {:http_request, :PUT, _, _}} = :gen_tcp.recv(socket, 0, 5_000)
    headers = receive_headers(socket, %{})
    :ok = :inet.setopts(socket, packet: :raw)

    early =
      case :gen_tcp.recv(socket, 0, 1_500) do
        {:ok, data} -> data
        {:error, :timeout} -> <<>>
      end

    send(parent, {:early_body_bytes, byte_size(early)})
    remaining = String.to_integer(headers["content-length"]) - byte_size(early)

    rest =
      if remaining > 0 do
        {:ok, data} = :gen_tcp.recv(socket, remaining, 8_000)
        data
      else
        <<>>
      end

    rows = Jason.decode!(early <> rest)
    send(parent, {:wire_request, Enum.map(rows, & &1["id"])})

    response =
      Jason.encode!(%{
        "Status" => "Success",
        "NumberLoadedRows" => length(rows),
        "NumberFilteredRows" => 0
      })

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ",
        Integer.to_string(byte_size(response)),
        "\r\n\r\n",
        response
      ])

    :gen_tcp.close(socket)
  end

  defp serve_publish_timeout_then_state(listener, parent) do
    {:ok, socket} = :gen_tcp.accept(listener, 5_000)
    {:ok, {:http_request, :PUT, _, _}} = :gen_tcp.recv(socket, 0, 5_000)
    _headers = receive_headers(socket, %{})
    :ok = :inet.setopts(socket, packet: :raw)

    early =
      case :gen_tcp.recv(socket, 0, 300) do
        {:ok, data} -> byte_size(data)
        {:error, _timeout_or_closed} -> 0
      end

    send(parent, {:load_early_body_bytes, early})
    response = Jason.encode!(%{"Status" => "Publish Timeout"})

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ",
        Integer.to_string(byte_size(response)),
        "\r\n\r\n",
        response
      ])

    :gen_tcp.close(socket)

    {:ok, state} = :gen_tcp.accept(listener, 5_000)
    {:ok, {:http_request, method, {:abs_path, path}, _}} = :gen_tcp.recv(state, 0, 5_000)
    headers = receive_headers(state, %{})
    method = method |> to_string() |> String.downcase() |> String.to_atom()
    send(parent, {:state_poll, method, path, headers})
    body = load_state_body("VISIBLE")

    :ok =
      :gen_tcp.send(state, [
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ",
        Integer.to_string(byte_size(body)),
        "\r\n\r\n",
        body
      ])

    :gen_tcp.close(state)
  end

  defp read_wire_request(socket, parent) do
    {:ok, {:http_request, :PUT, _, _}} = :gen_tcp.recv(socket, 0, 5_000)
    headers = receive_headers(socket, %{})
    :ok = :gen_tcp.send(socket, "HTTP/1.1 100 Continue\r\n\r\n")
    :ok = :inet.setopts(socket, packet: :raw)

    {:ok, body} =
      :gen_tcp.recv(socket, String.to_integer(headers["content-length"]), 5_000)

    rows = Jason.decode!(body)
    send(parent, {:wire_request, rows})
    rows
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

  defp state_path(label), do: "/api/serviceradar/get_load_state?label=#{label}"

  defp header_value(headers, name) do
    Enum.find_value(headers, fn
      {key, value} -> if String.downcase(key) == name, do: value
      _ -> nil
    end)
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
