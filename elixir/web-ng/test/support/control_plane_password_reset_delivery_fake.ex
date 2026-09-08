defmodule ServiceRadarWebNGWeb.ControlPlanePasswordResetDeliveryFake do
  @moduledoc false

  def deliver(email, _opts) do
    case Application.get_env(:serviceradar_web_ng, :control_plane_password_reset_test_pid) do
      pid when is_pid(pid) -> send(pid, {:password_reset_requested, email})
      _other -> :ok
    end

    Application.get_env(
      :serviceradar_web_ng,
      :control_plane_password_reset_test_response,
      {:error, :request_rejected}
    )
  end
end
