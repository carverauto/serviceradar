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
end
