defmodule ServiceRadarCoreElx.CameraRelay.ReferenceAnalysisWorker do
  @moduledoc """
  Small reference-only HTTP worker for the camera analysis contract.

  This is executable documentation for the `camera_analysis_input.v1` ->
  `camera_analysis_result.v1` contract. It is intentionally deterministic and
  lightweight. It is not a production CV or ML pipeline.
  """

  use Plug.Router

  @default_host {127, 0, 0, 1}
  @default_worker_id "reference-analysis-worker"

  plug(Plug.Logger, log: :debug)
  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(:match)
  plug(:dispatch)

  post "/analyze" do
    case analyze_input(conn.body_params, conn.private[:reference_analysis_worker_opts] || []) do
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

    with "camera_analysis_input.v1" <- value(input, :schema),
         relay_session_id when is_binary(relay_session_id) and relay_session_id != "" <-
           string_value(input, :relay_session_id),
         branch_id when is_binary(branch_id) and branch_id != "" <- string_value(input, :branch_id) do
      {:ok, build_results(input, relay_session_id, branch_id, worker_id)}
    else
      _ -> {:error, :invalid_input}
    end
  end

  def analyze_input(_input, _opts), do: {:error, :invalid_input}

  def init(opts) do
    opts
  end

  def call(conn, opts) do
    conn
    |> Plug.Conn.put_private(:reference_analysis_worker_opts, opts)
    |> super(opts)
  end

  defp build_results(input, relay_session_id, branch_id, worker_id) do
    if value(input, :keyframe) == true and supported_video_input?(input) do
      [
        %{
          "schema" => "camera_analysis_result.v1",
          "relay_session_id" => relay_session_id,
          "branch_id" => branch_id,
          "worker_id" => worker_id,
          "media_ingest_id" => string_value(input, :media_ingest_id),
          "sequence" => value(input, :sequence, 0),
          "detection" => %{
            "kind" => "reference_keyframe_detection",
            "label" => detection_label(input),
            "confidence" => 1.0,
            "attributes" => %{
              "reference_worker" => true,
              "codec" => string_value(input, :codec),
              "payload_format" => string_value(input, :payload_format)
            }
          },
          "metadata" => %{
            "analysis_mode" => "reference",
            "reference_worker" => true
          }
        }
      ]
    else
      []
    end
  end

  defp supported_video_input?(input) do
    string_value(input, :codec) in ["h264", "H264"] and
      string_value(input, :payload_format) in ["annexb", "nalu"]
  end

  defp detection_label(input) do
    codec = string_value(input, :codec) || "unknown"
    payload_format = string_value(input, :payload_format) || "unknown"
    "#{codec}_#{payload_format}_keyframe"
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
  defp error_message(reason), do: inspect(reason)
end
