defmodule ServiceRadarCoreElx.CameraRelay.AnalysisWorkerResolverTest do
  use ExUnit.Case, async: true

  alias ServiceRadarCoreElx.CameraRelay.AnalysisWorkerResolver

  defmodule ResourceStub do
    @moduledoc false

    def get_by_worker_id("worker-http", _opts) do
      {:ok,
       %{
         worker_id: "worker-http",
         adapter: "http",
         endpoint_url: "http://worker-http.local/analyze",
         capabilities: ["object_detection", "people_count"],
         enabled: true,
         headers: %{"authorization" => "Bearer token"}
       }}
    end

    def get_by_worker_id("worker-disabled", _opts) do
      {:ok,
       %{
         worker_id: "worker-disabled",
         adapter: "http",
         endpoint_url: "http://worker-disabled.local/analyze",
         capabilities: ["object_detection"],
         enabled: false,
         headers: %{}
       }}
    end

    def get_by_worker_id("worker-grpc", _opts) do
      {:ok,
       %{
         worker_id: "worker-grpc",
         adapter: "grpc",
         endpoint_url: "grpc://worker-grpc.local/analyze",
         capabilities: ["object_detection"],
         enabled: true,
         headers: %{}
       }}
    end

    def get_by_worker_id(_worker_id, _opts), do: {:ok, nil}

    def list_enabled(_opts) do
      {:ok,
       [
         %{
           worker_id: "worker-alpha",
           adapter: "http",
           endpoint_url: "http://worker-alpha.local/analyze",
           capabilities: ["plate_read"],
           enabled: true,
           headers: %{}
         },
         %{
           worker_id: "worker-beta",
           adapter: "http",
           endpoint_url: "http://worker-beta.local/analyze",
           capabilities: ["object_detection", "people_count"],
           enabled: true,
           headers: %{"x-token" => "beta"}
         }
       ]}
    end
  end

  test "uses direct endpoint configuration when endpoint_url is supplied" do
    assert {:ok, worker} =
             AnalysisWorkerResolver.resolve_http_worker(
               %{
                 worker_id: "direct-worker",
                 endpoint_url: "http://worker.local/analyze",
                 headers: %{"authorization" => "Bearer direct"}
               },
               resource: ResourceStub
             )

    assert worker.worker_id == "direct-worker"
    assert worker.endpoint_url == "http://worker.local/analyze"
    assert worker.selection_mode == "direct"
    assert worker.headers == %{"authorization" => "Bearer direct"}
  end

  test "resolves a registered worker by explicit id" do
    assert {:ok, worker} =
             AnalysisWorkerResolver.resolve_http_worker(
               %{registered_worker_id: "worker-http"},
               resource: ResourceStub
             )

    assert worker.worker_id == "worker-http"
    assert worker.endpoint_url == "http://worker-http.local/analyze"
    assert worker.selection_mode == "worker_id"
  end

  test "resolves a registered worker by capability match" do
    assert {:ok, worker} =
             AnalysisWorkerResolver.resolve_http_worker(
               %{required_capability: "object_detection"},
               resource: ResourceStub
             )

    assert worker.worker_id == "worker-beta"
    assert worker.selection_mode == "capability"
    assert worker.requested_capability == "object_detection"
  end

  test "returns bounded failures for disabled, mismatched, and unsupported workers" do
    assert {:error, :worker_unavailable} =
             AnalysisWorkerResolver.resolve_http_worker(
               %{registered_worker_id: "worker-disabled"},
               resource: ResourceStub
             )

    assert {:error, :worker_capability_unmatched} =
             AnalysisWorkerResolver.resolve_http_worker(
               %{registered_worker_id: "worker-http", required_capability: "plate_read"},
               resource: ResourceStub
             )

    assert {:error, {:unsupported_worker_adapter, "grpc"}} =
             AnalysisWorkerResolver.resolve_http_worker(
               %{registered_worker_id: "worker-grpc"},
               resource: ResourceStub
             )
  end
end
