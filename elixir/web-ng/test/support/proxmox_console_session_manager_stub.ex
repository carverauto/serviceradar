defmodule ServiceRadarWebNG.TestSupport.ProxmoxConsoleSessionManagerStub do
  @moduledoc false

  alias ServiceRadar.Edge.ProxmoxConsoleSession

  def request_open(device_uid, request, opts) do
    send(test_pid(), {:open_proxmox_console_session, device_uid, request, opts})

    Application.get_env(
      :serviceradar_web_ng,
      :proxmox_console_session_manager_open_result,
      {:ok,
       %{
         session: %ProxmoxConsoleSession{
           id: Ecto.UUID.generate(),
           device_uid: device_uid,
           target_kind: :pve_host,
           console_mode: :ssh,
           agent_id: "agent-1",
           gateway_id: "gateway-1",
           credential_rule_id: Ecto.UUID.generate(),
           status: :requested,
           ticket_expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
           idle_timeout_seconds: 900,
           absolute_timeout_seconds: 3600,
           inserted_at: DateTime.utc_now(),
           updated_at: DateTime.utc_now()
         },
         ticket: "srpve_test_ticket_value"
       }}
    )
  end

  def request_close(session_id, opts) do
    send(test_pid(), {:close_proxmox_console_session, session_id, opts})

    Application.get_env(
      :serviceradar_web_ng,
      :proxmox_console_session_manager_close_result,
      {:ok,
       %ProxmoxConsoleSession{
         id: session_id,
         device_uid: "device-1",
         target_kind: :pve_host,
         console_mode: :ssh,
         agent_id: "agent-1",
         gateway_id: "gateway-1",
         credential_rule_id: Ecto.UUID.generate(),
         status: :closing,
         ticket_expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
         idle_timeout_seconds: 900,
         absolute_timeout_seconds: 3600,
         close_reason: Keyword.get(opts, :reason) || "operator_requested",
         inserted_at: DateTime.utc_now(),
         updated_at: DateTime.utc_now()
       }}
    )
  end

  defp test_pid do
    Application.get_env(:serviceradar_web_ng, :proxmox_console_session_manager_test_pid, self())
  end
end
