defmodule ServiceRadarNVR.Health do
  @moduledoc "Runtime and storage probes only. These endpoints do not grant recording admission."
  @behaviour Plug

  import Plug.Conn

  alias ServiceRadarRecording.Storage

  @impl true
  def init(config), do: config

  @impl true
  def call(%{method: "GET", request_path: "/healthz"} = conn, _config), do: send_resp(conn, 200, "ok")

  def call(%{method: "GET", request_path: "/readyz"} = conn, config) do
    case ready(config) do
      :ok -> send_resp(conn, 200, "ready")
      :error -> send_resp(conn, 503, "storage unavailable")
    end
  end

  def call(conn, _config), do: send_resp(conn, 404, "not found")

  defp ready(%{root: nil}), do: :error

  defp ready(config) do
    with pid when is_pid(pid) <- Process.whereis(ServiceRadarNVR.Sessions),
         :ok <- ServiceRadarRecordingControl.RecoveryGate.check(config.recovery_gate),
         {:ok, _storage} <- Storage.open(config.root, config.storage_id),
         do: :ok,
         else: (_ -> :error)
  end
end
