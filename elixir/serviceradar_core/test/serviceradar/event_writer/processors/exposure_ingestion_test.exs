defmodule ServiceRadar.EventWriter.Processors.ExposureIngestionTest do
  use ExUnit.Case, async: false

  alias Broadway.Message
  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.LoadSupervisor
  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.Pipeline
  alias ServiceRadar.EventWriter.Processors.ExposureTransitions

  @moduletag :db_free

  setup do
    previous = Application.get_env(:serviceradar_core, StarRocks, [])
    on_exit(fn -> Application.put_env(:serviceradar_core, StarRocks, previous) end)
    start_supervised!(LoadSupervisor)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()
    start_supervised!({Task, fn -> serve(listener, parent) end})

    Application.put_env(:serviceradar_core, StarRocks,
      enabled: true,
      fe_http: "http://127.0.0.1:#{port}"
    )

    :ok
  end

  test "a routed after-image loads current state and complete history before acknowledging" do
    newest = transition(12, %{"kev" => true, "cvss_score" => 9.4, "pkgver_ord" => 103})
    older = transition(11, %{"kev" => true, "cvss_score" => 6.2})

    message = %Message{
      data: Jason.encode!(newest),
      metadata: %{subject: "vulnerability.assessment.transitions.3"},
      acknowledger: {Pipeline, :ref, %{}}
    }

    routed = Pipeline.handle_message(:default, message, %{})
    processor = Pipeline.processor_for_batcher(routed.batcher)
    task = Task.async(fn -> processor.process_batch([routed, encode(older)]) end)

    assert_receive {:load, facts_http, "/api/serviceradar/exposure_facts/_stream_load", headers,
                    [fact]},
                   2_000

    assert headers["partial_update"] == "true"
    assert headers["merge_condition"] == "transition_seq"
    columns = String.split(headers["columns"], ",")
    assert Enum.sort(columns) == Enum.sort(Map.keys(fact))
    refute "snapshot_generation" in columns

    assert fact == %{
             "device_ord" => 4_294_967_295,
             "cve_ord" => 20_240_000_001,
             "pkg_ord" => 7,
             "pkgver_ord" => 103,
             "state" => 1,
             "source_scope" => "host",
             "severity_rank" => 4,
             "cvss_score" => 9.4,
             "kev" => true,
             "exploit_available" => false,
             "fix_available" => true,
             "first_exposed_at" => "2000-01-01 00:00:00",
             "resolved_at" => nil,
             "updated_at" => "2000-01-02 00:00:00",
             "transition_seq" => 12,
             "transition_xid" => 512
           }

    assert Task.yield(task, 20) == nil
    send(facts_http, :commit)

    assert_receive {:load, history_http,
                    "/api/serviceradar/exposure_transitions_log/_stream_load", history_headers,
                    history},
                   2_000

    refute Map.has_key?(history_headers, "partial_update")
    refute history_headers["label"] == headers["label"]
    assert Enum.sort(Enum.map(history, & &1["transition_seq"])) == [11, 12]
    assert Enum.find(history, &(&1["transition_seq"] == 12))["payload"] == newest
    assert Task.yield(task, 20) == nil
    send(history_http, :commit)
    assert {:ok, 2} = Task.await(task)

    # Identical replay reuses load labels; changed content has a new sequence
    # and therefore cannot be mistaken for the previous successful load.
    for {payload, same_label?} <- [
          {newest, true},
          {transition(13, %{"state" => "resolved", "resolved_at" => "2000-01-02T00:00:00"}),
           false}
        ] do
      replay = Task.async(fn -> processor.process_batch([encode(payload)]) end)

      assert_receive {:load, http, "/api/serviceradar/exposure_facts/_stream_load",
                      replay_headers, [row]},
                     2_000

      assert replay_headers["label"] == headers["label"] == same_label?
      assert row["state"] == if(same_label?, do: 1, else: 0)
      send(http, :commit)

      assert_receive {:load, http, "/api/serviceradar/exposure_transitions_log/_stream_load", _,
                      [_]},
                     2_000

      send(http, :commit)
      assert {:ok, 1} = Task.await(replay)
    end
  end

  test "failed or filtered fact and history loads fail the batch" do
    for stage <- [:facts, :history], result <- [:failure, :filtered] do
      task = Task.async(fn -> ExposureTransitions.process_batch([encode(transition(25))]) end)
      assert_receive {:load, http, "/api/serviceradar/exposure_facts/_stream_load", _, [_]}, 2_000

      http =
        if stage == :history do
          send(http, :commit)

          assert_receive {:load, history_http,
                          "/api/serviceradar/exposure_transitions_log/_stream_load", _, [_]},
                         2_000

          history_http
        else
          http
        end

      send(http, result)
      assert {:error, {:warehouse_load, dataset, _reason}} = Task.await(task)
      assert dataset == if(stage == :facts, do: :exposure_facts, else: :exposure_transitions_log)
      refute_receive {:load, _, _, _, _}, 20
    end
  end

  test "the consumer attaches only with StarRocks and never creates the producer's stream" do
    stream = Enum.find(Config.load().streams, &(&1.name == "EXPOSURE_TRANSITIONS"))
    assert stream.subject == "vulnerability.assessment.transitions.>"
    assert stream.ensure_stream == false

    Application.put_env(:serviceradar_core, StarRocks, enabled: false)
    refute Enum.any?(Config.load().streams, &(&1.name == "EXPOSURE_TRANSITIONS"))

    assert {:error, :starrocks_required} =
             ExposureTransitions.process_batch([encode(transition(1))])

    refute_receive {:load, _, _, _, _}, 20
  end

  test "missing device ordinals are counted; invalid or incomplete after-images are not loaded" do
    parent = self()
    handler = "exposure-dropped-#{System.unique_integer([:positive])}"
    event = [:serviceradar, :exposure, :transition, :dropped]

    :telemetry.attach(
      handler,
      event,
      fn _, measurements, metadata, _ -> send(parent, {:dropped, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, 0} =
             ExposureTransitions.process_batch([encode(transition(1, %{"device_ord" => nil}))])

    assert_received {:dropped, %{count: 1}, %{reason: :missing_device_ordinal}}

    invalid =
      for value <- [0, -1, 4_294_967_296, "7"], do: transition(1, %{"device_ord" => value})

    for payload <-
          invalid ++
            [
              Map.delete(transition(1), "kev"),
              Map.delete(transition(1), "severity"),
              transition(1, %{"severity" => 3}),
              transition(1, %{"severity" => ["high"]}),
              transition(1, %{"schema_version" => 2}),
              transition(1, %{"transition_seq" => 0})
            ] do
      assert {:error, :invalid_exposure_transition} =
               ExposureTransitions.process_batch([encode(payload)])
    end

    refute_receive {:load, _, _, _, _}, 20
  end

  test "a batch keeps known ranks and stores unrecognized severities with their original history" do
    high = transition(40, %{"cve_ord" => 20_240_000_011, "severity" => "high"})
    negligible = transition(41, %{"cve_ord" => 20_240_000_012, "severity" => "negligible"})
    informational = transition(42, %{"cve_ord" => 20_240_000_013, "severity" => "informational"})
    absent = transition(43, %{"cve_ord" => 20_240_000_014, "severity" => nil})

    task =
      Task.async(fn ->
        ExposureTransitions.process_batch([
          encode(informational),
          encode(high),
          encode(negligible),
          encode(absent)
        ])
      end)

    assert_receive {:load, facts_http, "/api/serviceradar/exposure_facts/_stream_load", _, facts},
                   2_000

    assert Map.new(facts, &{&1["cve_ord"], &1["severity_rank"]}) == %{
             20_240_000_011 => 3,
             20_240_000_012 => nil,
             20_240_000_013 => nil,
             20_240_000_014 => nil
           }

    send(facts_http, :commit)

    assert_receive {:load, history_http,
                    "/api/serviceradar/exposure_transitions_log/_stream_load", _, history},
                   2_000

    assert Map.new(history, &{&1["payload"]["cve_ord"], &1["payload"]["severity"]}) == %{
             20_240_000_011 => "high",
             20_240_000_012 => "negligible",
             20_240_000_013 => "informational",
             20_240_000_014 => nil
           }

    send(history_http, :commit)
    assert {:ok, 4} = Task.await(task)
  end

  test "dimension subjects route complete rows and preserve separate package versions" do
    cve = dimension("cve", 100, %{"epss_score" => 0.8})
    older = dimension("cve", 99, %{"epss_score" => 0.2})
    package = dimension("package", 101)

    other_version =
      dimension("package", 102, %{"pkgver_ord" => 102, "installed_version" => "2.0"})

    for kind <- ["cve", "package"] do
      message = %Message{
        data: Jason.encode!(dimension(kind, 1)),
        metadata: %{subject: "exposure.dimensions.#{kind}"},
        acknowledger: {Pipeline, :ref, %{}}
      }

      assert Pipeline.handle_message(:default, message, %{}).batcher == :exposure_dimensions
    end

    processor = Pipeline.processor_for_batcher(:exposure_dimensions)
    messages = Enum.map([cve, older, cve, package, other_version], &encode/1)
    task = Task.async(fn -> processor.process_batch(messages) end)

    assert_receive {:load, http, "/api/serviceradar/exposure_cve_dim/_stream_load", headers,
                    [row]},
                   2_000

    assert headers["merge_condition"] == "transition_seq"

    assert row == %{
             "cve_ord" => 20_240_000_001,
             "cve_id" => "CVE-2024-0001",
             "epss_score" => 0.8,
             "transition_seq" => 100,
             "updated_at" => "2000-01-02 00:00:00"
           }

    assert Task.yield(task, 20) == nil
    send(http, :commit)

    assert_receive {:load, http, "/api/serviceradar/exposure_package_dim/_stream_load",
                    package_headers, rows},
                   2_000

    assert package_headers["merge_condition"] == "transition_seq"
    assert Enum.sort(Enum.map(rows, & &1["installed_version"])) == ["1.0", "2.0"]
    assert Enum.all?(rows, &(&1["pkg_ord"] == 7 and &1["package_name"] == "examplelib"))
    refute package_headers["label"] == headers["label"]
    send(http, :commit)
    assert {:ok, 5} = Task.await(task)

    task = Task.async(fn -> processor.process_batch([encode(cve)]) end)
    assert_receive {:load, http, _, replay_headers, [_]}, 2_000
    assert replay_headers["label"] == headers["label"]
    send(http, :commit)
    assert {:ok, 1} = Task.await(task)
  end

  test "dimension null clears are explicit and failed or filtered loads fail the batch" do
    processor = Pipeline.processor_for_batcher(:exposure_dimensions)

    for kind <- ["cve", "package"], result <- [:commit, :failure, :filtered] do
      task = Task.async(fn -> processor.process_batch([encode(dimension(kind, 200))]) end)
      assert_receive {:load, http, _, _, [row]}, 2_000
      if kind == "cve", do: assert(Map.has_key?(row, "epss_score") and is_nil(row["epss_score"]))
      send(http, result)

      if result == :commit do
        assert {:ok, 1} = Task.await(task)
      else
        assert {:error, {:warehouse_load, _, _}} = Task.await(task)
      end
    end
  end

  test "dimension validation rejects incomplete rows and the consumer requires StarRocks" do
    processor = Pipeline.processor_for_batcher(:exposure_dimensions)

    for payload <- [
          Map.delete(dimension("cve", 1), "epss_score"),
          dimension("cve", 1, %{"epss_score" => 1.1}),
          dimension("cve", 1, %{"epss_score" => "0.5"}),
          dimension("package", 1, %{"pkgver_ord" => 0}),
          dimension("package", 0),
          dimension("package", 1, %{"installed_version" => nil})
        ] do
      assert {:error, :invalid_exposure_dimension} = processor.process_batch([encode(payload)])
    end

    stream = Enum.find(Config.load().streams, &(&1.name == "EXPOSURE_DIMENSIONS"))
    assert stream.ensure_stream == false
    Application.put_env(:serviceradar_core, StarRocks, enabled: false)
    refute Enum.any?(Config.load().streams, &(&1.name == "EXPOSURE_DIMENSIONS"))
    assert {:error, :starrocks_required} = processor.process_batch([encode(dimension("cve", 1))])
    refute_receive {:load, _, _, _, _}, 20
  end

  defp dimension(kind, sequence, overrides \\ %{}) do
    fields =
      case kind do
        "cve" ->
          %{"cve_ord" => 20_240_000_001, "cve_id" => "CVE-2024-0001", "epss_score" => nil}

        "package" ->
          %{
            "pkgver_ord" => 101,
            "pkg_ord" => 7,
            "package_identity_key" => "synthetic-package-alpha",
            "installed_version" => "1.0",
            "package_name" => "examplelib"
          }
      end

    fields
    |> Map.merge(%{
      "schema_version" => 1,
      "dimension" => kind,
      "transition_seq" => sequence,
      "updated_at" => "2000-01-02T00:00:00.123456"
    })
    |> Map.merge(overrides)
  end

  defp transition(sequence, overrides \\ %{}) do
    Map.merge(
      %{
        "schema_version" => 1,
        "device_ord" => 4_294_967_295,
        "cve_ord" => 20_240_000_001,
        "pkg_ord" => 7,
        "pkgver_ord" => 101,
        "transition_seq" => sequence,
        "transition_xid" => 500 + sequence,
        "state" => "active",
        "source_scope" => "host",
        "severity" => "critical",
        "cvss_score" => 8.1,
        "kev" => false,
        "exploit_available" => false,
        "fix_available" => true,
        "first_exposed_at" => "2000-01-01T00:00:00",
        "resolved_at" => nil,
        "changed_at" => "2000-01-02T00:00:00.123456",
        "reason" => "actionable_attributes_changed",
        "changed_fields" => ["kev", "cvss_score"],
        "cve_id" => "CVE-2024-0001",
        "package_identity_key" => "synthetic-package-alpha",
        "installed_version" => "1.2.0"
      },
      overrides
    )
  end

  defp encode(payload), do: %{data: Jason.encode!(payload)}

  # Exercise the real HTTP loader and acknowledgement boundary, without
  # replacing the processor or implementing a fake warehouse's merge rules.
  defp serve(listener, parent) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
        ["PUT", path, _] = String.split(request)
        headers = headers(socket, %{})
        :ok = :gen_tcp.send(socket, "HTTP/1.1 100 Continue\r\n\r\n")
        :ok = :inet.setopts(socket, packet: :raw)
        {:ok, body} = :gen_tcp.recv(socket, String.to_integer(headers["content-length"]), 5_000)
        rows = Jason.decode!(body)
        send(parent, {:load, self(), path, headers, rows})

        response =
          receive do
            :commit ->
              %{
                "Status" => "Success",
                "NumberLoadedRows" => length(rows),
                "NumberFilteredRows" => 0
              }

            :filtered ->
              %{"Status" => "Success", "NumberLoadedRows" => 0, "NumberFilteredRows" => 1}

            :failure ->
              %{"Status" => "Fail", "Message" => "synthetic load failure"}
          after
            5_000 -> raise "load was never answered"
          end

        body = Jason.encode!(response)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\nContent-Length: ",
            Integer.to_string(byte_size(body)),
            "\r\nConnection: close\r\n\r\n",
            body
          ])

        :gen_tcp.close(socket)
        serve(listener, parent)

      {:error, :closed} ->
        :ok
    end
  end

  defp headers(socket, acc) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)

    case String.split(String.trim(line), ":", parts: 2) do
      [""] -> acc
      [key, value] -> headers(socket, Map.put(acc, String.downcase(key), String.trim(value)))
    end
  end
end
