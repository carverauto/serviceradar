defmodule ServiceRadarWebNG.Dashboards.FrameRunnerTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Dashboards.FrameRunner

  @moduletag :db_free

  defmodule FakeSRQL do
    @moduledoc false
    def query("in:devices", opts) do
      limit = Map.fetch!(opts, :limit)

      {:ok,
       %{
         "results" => Enum.map(1..limit, &%{"id" => &1}),
         "pagination" => %{"limit" => limit},
         "schema" => %{"columns" => ["id"]}
       }}
    end

    def query("bad", _opts), do: {:error, :bad_query}

    def query("in:security_findings", _opts) do
      {:ok,
       %{
         "results" => [
           %{
             "id" => "finding-1",
             "metadata" => %{"service_radar" => %{"source_type" => "falco"}},
             "observables" => [%{"name" => "unused"}],
             "actor" => %{"name" => "unused"},
             "src_endpoint" => %{"ip" => "10.0.2.11"},
             "dst_endpoint" => %{"ip" => "192.0.2.20"},
             "raw_data" =>
               Jason.encode!(%{
                 "output_fields" => %{"k8s.node.name" => "k8s-cp3-worker1"},
                 "correlation" => %{"host_ip" => "10.0.2.11"}
               })
           }
         ]
       }}
    end

    def query("in:events falco-sidekick", _opts) do
      {:ok,
       %{
         "results" => [
           %{
             "id" => "falco-1",
             "raw_data" => %{
               "custom_fields" => %{"serviceradar.agent_id" => "agent-k8s-cp3-worker1"},
               "templated_fields" => %{"k8s.node.name" => "k8s-cp3-worker1"}
             }
           }
         ]
       }}
    end

    def query("in:events bumblebee", _opts) do
      {:ok,
       %{
         "results" => [
           %{
             "id" => "bumblebee-1",
             "raw_data" => %{
               "metadata" => %{
                 "service_radar" => %{
                   "agent_id" => "agent-sr-test-pve04",
                   "device_uid" => "sr:2a4f3940-be57-4a79-b4a5-2a1ea096d02f"
                 }
               },
               "device" => %{"name" => "agent-sr-test-pve04"}
             }
           }
         ]
       }}
    end
  end

  defmodule FakeDeviceResolver do
    @moduledoc false

    def resolve(%{hostname: "k8s-cp3-worker1", ip: "10.0.2.11"}) do
      "sr:9a6211a0-46d9-4986-988d-01e14d886e40"
    end

    def resolve(_candidate), do: nil
  end

  defmodule FakeArrowSRQL do
    @moduledoc false

    def query(_query, _opts), do: {:error, :json_should_not_run}

    def query_arrow("in:devices", opts) do
      limit = Map.fetch!(opts, :limit)

      {:ok,
       %{
         payload: "arrow-ipc:#{limit}",
         schema: %{"columns" => ["id"]},
         pagination: %{"limit" => limit}
       }}
    end
  end

  defmodule FakeCursorSRQL do
    @moduledoc false

    def query(query, opts) when is_binary(query) do
      {:ok,
       %{
         "results" => [
           %{
             "query" => query,
             "cursor" => Map.get(opts, :cursor),
             "limit" => Map.get(opts, :limit)
           }
         ],
         "pagination" => %{
           "next_cursor" => "next-token",
           "prev_cursor" => Map.get(opts, :cursor),
           "limit" => Map.get(opts, :limit)
         }
       }}
    end
  end

  defmodule FakeConcurrentSRQL do
    @moduledoc false

    def query("blocking:" <> id, %{scope: parent}) do
      send(parent, {:frame_started, id, self()})

      receive do
        {:continue_frame, ^id} ->
          {:ok, %{"results" => [%{"id" => id}]}}
      end
    end

    def query("never_returns", %{scope: parent}) do
      send(parent, {:frame_started, "timeout", self()})
      Process.sleep(:infinity)
    end
  end

  test "falls back to bounded JSON rows when Arrow IPC is not available" do
    frames = [
      %{
        "id" => "devices",
        "query" => "in:devices",
        "encoding" => "arrow_ipc",
        "limit" => 3
      }
    ]

    assert [
             %{
               "id" => "devices",
               "status" => "ok",
               "requested_encoding" => "arrow_ipc",
               "encoding" => "json_rows",
               "limit" => 3,
               "schema" => %{"columns" => ["id"]},
               "results" => [%{"id" => 1}, %{"id" => 2}, %{"id" => 3}]
             }
           ] = FrameRunner.run(frames, :scope, srql_module: FakeSRQL)
  end

  test "returns Arrow IPC frame payloads when the SRQL module supports them" do
    frames = [
      %{
        "id" => "devices",
        "query" => "in:devices",
        "encoding" => "arrow_ipc",
        "limit" => 3
      }
    ]

    assert [
             %{
               "id" => "devices",
               "status" => "ok",
               "requested_encoding" => "arrow_ipc",
               "encoding" => "arrow_ipc",
               "payload_encoding" => "base64",
               "payload" => payload,
               "byte_length" => 11,
               "results" => [],
               "schema" => %{"columns" => ["id"]},
               "pagination" => %{"limit" => 3}
             }
           ] = FrameRunner.run(frames, :scope, srql_module: FakeArrowSRQL)

    assert Base.decode64!(payload) == "arrow-ipc:3"
  end

  test "returns per-frame errors without failing all frames" do
    frames = [
      %{"id" => "bad", "query" => "bad", "encoding" => "json_rows"},
      %{"id" => "ok", "query" => "in:devices", "encoding" => "json_rows", "limit" => 1}
    ]

    assert [
             %{"id" => "bad", "status" => "error", "error" => ":bad_query", "results" => []},
             %{"id" => "ok", "status" => "ok", "results" => [%{"id" => 1}]}
           ] = FrameRunner.run(frames, :scope, srql_module: FakeSRQL)
  end

  test "runs frames concurrently while preserving manifest order" do
    parent = self()

    frames = [
      %{"id" => "first", "query" => "blocking:first", "encoding" => "json_rows", "limit" => 1},
      %{"id" => "second", "query" => "blocking:second", "encoding" => "json_rows", "limit" => 1}
    ]

    task =
      Task.async(fn ->
        FrameRunner.run(frames, parent, srql_module: FakeConcurrentSRQL, max_concurrency: 2)
      end)

    assert_receive {:frame_started, "first", first_pid}
    assert_receive {:frame_started, "second", second_pid}

    send(second_pid, {:continue_frame, "second"})
    send(first_pid, {:continue_frame, "first"})

    assert [
             %{"id" => "first", "status" => "ok", "results" => [%{"id" => "first"}]},
             %{"id" => "second", "status" => "ok", "results" => [%{"id" => "second"}]}
           ] = Task.await(task)
  end

  test "returns a timeout error frame for an individual slow frame" do
    parent = self()

    frames = [
      %{"id" => "slow", "query" => "never_returns", "encoding" => "json_rows", "limit" => 1},
      %{"id" => "ok", "query" => "blocking:ok", "encoding" => "json_rows", "limit" => 1}
    ]

    task =
      Task.async(fn ->
        FrameRunner.run(frames, parent,
          srql_module: FakeConcurrentSRQL,
          max_concurrency: 2,
          frame_timeout_ms: 25
        )
      end)

    assert_receive {:frame_started, "timeout", _slow_pid}
    assert_receive {:frame_started, "ok", ok_pid}

    send(ok_pid, {:continue_frame, "ok"})

    assert [
             %{"id" => "slow", "status" => "error", "error" => ":frame_timeout", "results" => []},
             %{"id" => "ok", "status" => "ok", "results" => [%{"id" => "ok"}]}
           ] = Task.await(task)
  end

  test "enriches event frames with resolved inventory device UIDs" do
    frames = [
      %{"id" => "findings", "query" => "in:security_findings", "encoding" => "json_rows", "limit" => 1}
    ]

    assert [
             %{
               "id" => "findings",
               "status" => "ok",
               "results" => [
                 %{
                   "id" => "finding-1",
                   "resolved_device_uid" => "sr:9a6211a0-46d9-4986-988d-01e14d886e40"
                 }
               ]
             }
           ] = FrameRunner.run(frames, :scope, srql_module: FakeSRQL, device_resolver: FakeDeviceResolver)
  end

  test "projects dashboard frame fields after event enrichment" do
    frames = [
      %{
        "id" => "findings",
        "query" => "in:security_findings",
        "encoding" => "json_rows",
        "limit" => 1,
        "fields" => ["id", "metadata"]
      }
    ]

    assert [
             %{
               "id" => "findings",
               "status" => "ok",
               "results" => [
                 %{
                   "id" => "finding-1",
                   "metadata" => %{"service_radar" => %{"source_type" => "falco"}},
                   "resolved_device_uid" => "sr:9a6211a0-46d9-4986-988d-01e14d886e40"
                 } = row
               ]
             }
           ] = FrameRunner.run(frames, :scope, srql_module: FakeSRQL, device_resolver: FakeDeviceResolver)

    refute Map.has_key?(row, "raw_data")
    refute Map.has_key?(row, "observables")
    refute Map.has_key?(row, "actor")
    refute Map.has_key?(row, "src_endpoint")
    refute Map.has_key?(row, "dst_endpoint")
  end

  test "uses Falcosidekick custom and templated fields for device resolution" do
    frames = [
      %{"id" => "falco", "query" => "in:events falco-sidekick", "encoding" => "json_rows", "limit" => 1}
    ]

    resolver = fn
      %{agent_id: "agent-k8s-cp3-worker1", hostname: "k8s-cp3-worker1"} ->
        "sr:falco-node"

      _candidate ->
        nil
    end

    assert [
             %{
               "id" => "falco",
               "status" => "ok",
               "results" => [
                 %{"id" => "falco-1", "resolved_device_uid" => "sr:falco-node"}
               ]
             }
           ] = FrameRunner.run(frames, :scope, srql_module: FakeSRQL, device_resolver: resolver)
  end

  test "uses map raw_data metadata from add-on events for device resolution" do
    frames = [
      %{"id" => "bumblebee", "query" => "in:events bumblebee", "encoding" => "json_rows", "limit" => 1}
    ]

    resolver = fn %{device_uid: device_uid} -> device_uid end

    assert [
             %{
               "id" => "bumblebee",
               "status" => "ok",
               "results" => [
                 %{
                   "id" => "bumblebee-1",
                   "resolved_device_uid" => "sr:2a4f3940-be57-4a79-b4a5-2a1ea096d02f"
                 }
               ]
             }
           ] = FrameRunner.run(frames, :scope, srql_module: FakeSRQL, device_resolver: resolver)
  end

  test "preserves explicit optional frame metadata" do
    frames = [
      %{"id" => "optional", "query" => "in:devices", "encoding" => "json_rows", "limit" => 1, "required" => false}
    ]

    assert [%{"id" => "optional", "required" => false}] = FrameRunner.run(frames, :scope, srql_module: FakeSRQL)
  end

  test "caps frame count and row limit" do
    frames =
      for index <- 1..20 do
        %{"id" => "f#{index}", "query" => "in:devices", "encoding" => "json_rows", "limit" => 10_000}
      end

    results = FrameRunner.run(frames, :scope, srql_module: FakeSRQL)

    assert length(results) == 12
    assert Enum.all?(results, &(length(&1["results"]) == 2_000))
  end

  test "forwards a frame cursor into the SRQL query opts" do
    frames = [
      %{
        "id" => "results",
        "query" => "in:composite_results sort:device_uid:asc limit:200",
        "encoding" => "json_rows",
        "limit" => 200,
        "cursor" => "page-two"
      }
    ]

    assert [
             %{
               "id" => "results",
               "status" => "ok",
               "results" => [%{"cursor" => "page-two", "limit" => 200}],
               "pagination" => %{"next_cursor" => "next-token", "prev_cursor" => "page-two"}
             }
           ] = FrameRunner.run(frames, :scope, srql_module: FakeCursorSRQL)
  end

  test "omits cursor from SRQL opts when the frame does not name one" do
    frames = [
      %{"id" => "results", "query" => "in:composite_results limit:200", "encoding" => "json_rows", "limit" => 200}
    ]

    assert [
             %{
               "results" => [%{"cursor" => nil, "limit" => 200}]
             }
           ] = FrameRunner.run(frames, :scope, srql_module: FakeCursorSRQL)
  end

  test "security findings source probes are optional" do
    manifest_path =
      Path.expand("../../../priv/dashboard-packages/security-findings/manifest.json", __DIR__)

    manifest = manifest_path |> File.read!() |> Jason.decode!()

    source_probe_ids =
      manifest["data_frames"]
      |> Enum.filter(fn frame -> String.ends_with?(frame["id"], "_latest") end)
      |> Enum.map(& &1["id"])

    assert source_probe_ids == [
             "trivy_findings_latest",
             "trivy_scan_latest",
             "bumblebee_findings_latest",
             "bumblebee_scan_latest",
             "falco_findings_latest",
             "endpoint_inventory_findings_latest",
             "powerdns_dns_latest"
           ]

    assert Enum.all?(manifest["data_frames"], fn frame ->
             id = frame["id"]

             if Enum.member?(source_probe_ids, id) do
               frame["required"] == false
             else
               true
             end
           end)
  end
end
