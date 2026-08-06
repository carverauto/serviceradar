defmodule ServiceRadarWebNG.TestSupport.RemoteAccessSessionManagerStub do
  @moduledoc false

  alias ServiceRadar.Edge.RemoteAccessSession

  def request_open(device_uid, request, opts) do
    send(test_pid(), {:open_remote_access_session, device_uid, request, opts})

    Application.get_env(
      :serviceradar_web_ng,
      :remote_access_session_manager_open_result,
      {:ok,
       %{
         session: %RemoteAccessSession{
           id: Ecto.UUID.generate(),
           device_uid: device_uid,
           target_kind: :inventory_device,
           target_host: request.target_host || device_uid,
           target_port: request.target_port || 22,
           protocol: :ssh,
           adapter: :ssh,
           agent_id: request.agent_id || "agent-1",
           gateway_id: request.gateway_id || "gateway-1",
           credential_custody_mode: :ssh_certificate,
           requested_by: scope_user_id(opts),
           status: :requested,
           rbac_decision: :allowed,
           attach_expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
           idle_timeout_seconds: 900,
           absolute_timeout_seconds: 3600,
           inserted_at: DateTime.utc_now(),
           updated_at: DateTime.utc_now()
         },
         ticket: "srra_test_ticket_value"
       }}
    )
  end

  def request_close(session_id, opts) do
    send(test_pid(), {:close_remote_access_session, session_id, opts})

    Application.get_env(
      :serviceradar_web_ng,
      :remote_access_session_manager_close_result,
      {:ok,
       %RemoteAccessSession{
         id: session_id,
         device_uid: "device-1",
         target_kind: :inventory_device,
         target_host: "device-1",
         target_port: 22,
         protocol: :ssh,
         adapter: :ssh,
         agent_id: "agent-1",
         gateway_id: "gateway-1",
         credential_custody_mode: :ssh_certificate,
         requested_by: scope_user_id(opts),
         status: :closing,
         rbac_decision: :allowed,
         attach_expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
         idle_timeout_seconds: 900,
         absolute_timeout_seconds: 3600,
         close_reason: Keyword.get(opts, :reason) || "operator_requested",
         inserted_at: DateTime.utc_now(),
         updated_at: DateTime.utc_now()
       }}
    )
  end

  def get_by_id(session_id, opts) do
    send(test_pid(), {:fetch_remote_access_session, session_id, opts})

    Application.get_env(
      :serviceradar_web_ng,
      :remote_access_session_manager_fetch_result,
      {:ok,
       %RemoteAccessSession{
         id: session_id,
         device_uid: "device-1",
         target_kind: :inventory_device,
         target_host: "device-1",
         target_port: 22,
         protocol: :ssh,
         adapter: :ssh,
         agent_id: "agent-1",
         gateway_id: "gateway-1",
         credential_custody_mode: :ssh_certificate,
         requested_by: scope_user_id(opts),
         status: :active,
         rbac_decision: :allowed,
         attach_expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
         idle_timeout_seconds: 900,
         absolute_timeout_seconds: 3600,
         inserted_at: DateTime.utc_now(),
         updated_at: DateTime.utc_now()
       }}
    )
  end

  def ssh_console_options(device_uid, opts) do
    send(test_pid(), {:ssh_console_options, device_uid, opts})

    Application.get_env(
      :serviceradar_web_ng,
      :remote_access_session_manager_ssh_options_result,
      {:ok,
       %{
         "default_credential_mode" => "ssh_certificate",
         "accounts" => [%{"name" => "mfreeman"}],
         "ttl_seconds" => 1800,
         "device_uid" => device_uid
       }}
    )
  end

  defp test_pid do
    Application.get_env(:serviceradar_web_ng, :remote_access_session_manager_test_pid, self())
  end

  defp scope_user_id(opts) do
    case Keyword.get(opts, :scope) do
      %{user: %{id: id}} -> id
      _scope -> nil
    end
  end
end
