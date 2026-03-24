defmodule ServiceRadarCoreElx.CameraRelay.AnalysisHTTPAdapterTest do
  use ExUnit.Case, async: true

  alias ServiceRadarCoreElx.CameraRelay.AnalysisHTTPAdapter

  defmodule ReqSuccessStub do
    @moduledoc false
    def post(_url, _opts) do
      {:ok, %Req.Response{status: 200, body: %{"detection" => %{"label" => "person"}}}}
    end
  end

  defmodule ReqListSuccessStub do
    @moduledoc false
    def post(_url, _opts) do
      {:ok,
       %Req.Response{
         status: 200,
         body: [%{"detection" => %{"label" => "person"}}, %{"detection" => %{"label" => "car"}}]
       }}
    end
  end

  defmodule ReqHTTPErrorStub do
    @moduledoc false
    def post(_url, _opts) do
      {:ok, %Req.Response{status: 503, body: %{"error" => "down"}}}
    end
  end

  defmodule ReqTimeoutStub do
    @moduledoc false
    def post(_url, _opts) do
      {:error, %Req.TransportError{reason: :timeout}}
    end
  end

  defmodule ReqInvalidBodyStub do
    @moduledoc false
    def post(_url, _opts) do
      {:ok, %Req.Response{status: 200, body: "not-json"}}
    end
  end

  defmodule ReqHealthSuccessStub do
    @moduledoc false
    def get(url, _opts) do
      send(self(), {:health_get, url})
      {:ok, %Req.Response{status: 200, body: %{"ok" => true}}}
    end
  end

  defmodule ReqHealthFailureStub do
    @moduledoc false
    def get(_url, _opts) do
      {:ok, %Req.Response{status: 503, body: %{"error" => "down"}}}
    end
  end

  test "normalizes a successful map response into a result list" do
    assert {:ok, [%{"detection" => %{"label" => "person"}}]} =
             AnalysisHTTPAdapter.deliver(
               %{schema: "camera_analysis_input.v1"},
               %{endpoint_url: "http://worker.local/analyze"},
               request_module: ReqSuccessStub
             )
  end

  test "accepts a successful list response" do
    assert {:ok, [%{"detection" => %{"label" => "person"}}, %{"detection" => %{"label" => "car"}}]} =
             AnalysisHTTPAdapter.deliver(
               %{schema: "camera_analysis_input.v1"},
               %{endpoint_url: "http://worker.local/analyze"},
               request_module: ReqListSuccessStub
             )
  end

  test "returns an http status error for non-2xx responses" do
    assert {:error, {:http_status, 503, %{"error" => "down"}}} =
             AnalysisHTTPAdapter.deliver(
               %{schema: "camera_analysis_input.v1"},
               %{endpoint_url: "http://worker.local/analyze"},
               request_module: ReqHTTPErrorStub
             )
  end

  test "returns timeout errors explicitly" do
    assert {:error, :timeout} =
             AnalysisHTTPAdapter.deliver(
               %{schema: "camera_analysis_input.v1"},
               %{endpoint_url: "http://worker.local/analyze"},
               request_module: ReqTimeoutStub
             )
  end

  test "rejects malformed successful responses" do
    assert {:error, :invalid_response} =
             AnalysisHTTPAdapter.deliver(
               %{schema: "camera_analysis_input.v1"},
               %{endpoint_url: "http://worker.local/analyze"},
               request_module: ReqInvalidBodyStub
             )
  end

  test "probes health using an explicit metadata endpoint when configured" do
    assert :ok =
             AnalysisHTTPAdapter.probe_health(
               %{
                 endpoint_url: "http://worker.local/analyze",
                 metadata: %{"health_endpoint_url" => "http://worker.local/readyz"}
               },
               request_module: ReqHealthSuccessStub
             )

    assert_receive {:health_get, "http://worker.local/readyz"}
  end

  test "prefers explicit probe fields over metadata fallback" do
    assert :ok =
             AnalysisHTTPAdapter.probe_health(
               %{
                 endpoint_url: "http://worker.local/analyze",
                 health_endpoint_url: "http://worker.local/probe",
                 health_timeout_ms: 1800,
                 metadata: %{
                   "health_endpoint_url" => "http://worker.local/readyz",
                   "health_timeout_ms" => 900
                 }
               },
               request_module: ReqHealthSuccessStub
             )

    assert_receive {:health_get, "http://worker.local/probe"}
  end

  test "derives a health path from the worker endpoint when no explicit endpoint is configured" do
    assert :ok =
             AnalysisHTTPAdapter.probe_health(
               %{
                 endpoint_url: "http://worker.local/analyze",
                 metadata: %{"health_path" => "/status"}
               },
               request_module: ReqHealthSuccessStub
             )

    assert_receive {:health_get, "http://worker.local/status"}
  end

  test "returns an http status error for failed health probes" do
    assert {:error, {:http_status, 503, %{"error" => "down"}}} =
             AnalysisHTTPAdapter.probe_health(
               %{
                 endpoint_url: "http://worker.local/analyze",
                 metadata: %{}
               },
               request_module: ReqHealthFailureStub
             )
  end
end
