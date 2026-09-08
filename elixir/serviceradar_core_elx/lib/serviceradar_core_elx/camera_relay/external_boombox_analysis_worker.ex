defmodule ServiceRadarCoreElx.CameraRelay.ExternalBoomboxAnalysisWorker do
  @moduledoc """
  Executable external HTTP worker that consumes bounded relay-derived H264
  samples, runs them through Boombox, and returns normalized analysis results.
  """

  use Plug.Router

  alias ServiceRadar.Camera.AnalysisContract
  alias ServiceRadarCoreElx.CameraRelay.BoomboxHelpers
  alias ServiceRadarCoreElx.CameraRelay.SecureTempCapture

  @default_host {127, 0, 0, 1}
  @default_worker_id "external-boombox-analysis-worker"

  plug(Plug.Logger, log: :debug)
  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(:match)
  plug(:dispatch)

  post "/analyze" do
    case analyze_input(conn.body_params, conn.private[:external_boombox_analysis_worker_opts] || []) do
      {:ok, results} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(results))

      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(422, Jason.encode!(%{error: error_message(reason)}))
    end
  end

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  def child_spec(opts) do
    bandit_opts = [
      plug: {__MODULE__, opts},
      scheme: :http,
      ip: Keyword.get(opts, :ip, @default_host),
      port: Keyword.fetch!(opts, :port)
    ]

    Supervisor.child_spec(Bandit.child_spec(bandit_opts), id: {__MODULE__, bandit_opts[:port]})
  end

  @spec analyze_input(map(), keyword()) :: {:ok, list(map())} | {:error, term()}
  def analyze_input(input, opts \\ [])

  def analyze_input(input, opts) when is_map(input) do
    worker_id = Keyword.get(opts, :worker_id, @default_worker_id)

    with {:ok, decoded_input} <- AnalysisContract.decode_transport_input(input),
         "camera_analysis_input.v1" <- value(decoded_input, :schema),
         relay_session_id when is_binary(relay_session_id) and relay_session_id != "" <-
           string_value(decoded_input, :relay_session_id),
         branch_id when is_binary(branch_id) and branch_id != "" <- string_value(decoded_input, :branch_id) do
      build_results(decoded_input, relay_session_id, branch_id, worker_id)
    else
      _ -> {:error, :invalid_input}
    end
  end

  def analyze_input(_input, _opts), do: {:error, :invalid_input}

  def init(opts), do: opts

  def call(conn, opts) do
    conn
    |> Plug.Conn.put_private(:external_boombox_analysis_worker_opts, opts)
    |> super(opts)
  end

  defp build_results(input, relay_session_id, branch_id, worker_id) do
    if value(input, :keyframe) == true and supported_video_input?(input) do
      with {:ok, image_metadata} <- decode_capture_with_boombox(value(input, :payload)) do
        {:ok,
         [
           %{
             "schema" => "camera_analysis_result.v1",
             "relay_session_id" => relay_session_id,
             "branch_id" => branch_id,
             "worker_id" => worker_id,
             "media_ingest_id" => string_value(input, :media_ingest_id),
             "sequence" => value(input, :sequence, 0),
             "detection" => %{
               "kind" => "boombox_external_keyframe_detection",
               "label" => detection_label(input),
               "confidence" => 1.0,
               "attributes" => %{
                 "analysis_mode" => "external_boombox",
                 "codec" => string_value(input, :codec),
                 "payload_format" => string_value(input, :payload_format),
                 "boombox_frame_width" => image_metadata.width,
                 "boombox_frame_height" => image_metadata.height
               }
             },
             "metadata" => %{
               "analysis_adapter" => "boombox_external",
               "analysis_mode" => "external_boombox",
               "boombox_frame_width" => image_metadata.width,
               "boombox_frame_height" => image_metadata.height
             }
           }
         ]}
      end
    else
      {:ok, []}
    end
  end

  defp supported_video_input?(input) do
    string_value(input, :codec) in ["h264", "H264"] and
      string_value(input, :payload_format) in ["annexb", "nalu"] and
      is_binary(value(input, :payload)) and byte_size(value(input, :payload)) > 0
  end

  defp detection_label(input) do
    codec = string_value(input, :codec) || "unknown"
    payload_format = string_value(input, :payload_format) || "unknown"
    "boombox_#{codec}_#{payload_format}_keyframe"
  end

  defp decode_capture_with_boombox(payload) when is_binary(payload) do
    SecureTempCapture.with_payload_file("serviceradar-external-boombox", payload, ".h264", fn path ->
      BoomboxHelpers.decode_capture(path)
    end)
  end

  defp string_value(input, key) do
    case value(input, key) do
      nil -> nil
      "" -> nil
      value -> to_string(value)
    end
  end

  defp value(input, key, default \\ nil) do
    Map.get(input, key, Map.get(input, to_string(key), default))
  end

  defp error_message(:invalid_input), do: "invalid camera analysis input"
end
