defmodule ServiceRadarWebNGWeb.Api.RemoteAccessSessionController do
  @moduledoc """
  Authenticated API for issuing generic remote-access session tickets.
  """

  use ServiceRadarWebNGWeb, :controller

  alias Ash.Error.Query.NotFound
  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadar.Inventory.Device
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNG.RemoteAccessDesktopTargets
  alias ServiceRadarWebNG.RemoteDesktopWebRTC
  alias ServiceRadarWebNGWeb.FeatureFlags

  action_fallback ServiceRadarWebNGWeb.Api.FallbackController

  @remote_access_ssh_permission "devices.remote_access.ssh.open"
  @remote_access_ssh_target_override_permission "devices.remote_access.ssh.target.override"
  @remote_access_rdp_permission "devices.remote_access.rdp.open"
  @base_ssh_host_key_policies ~w(known_hosts trust_on_first_use)
  @browser_selectable_ssh_custody_modes ~w(ssh_certificate user_present)
  @min_target_port 1
  @max_target_port 65_535
  @min_terminal_cols 1
  @max_terminal_cols 500
  @min_terminal_rows 1
  @max_terminal_rows 200
  @client_controlled_metadata_denylist ~w(
    accounts
    allowed_methods
    allowed_path_prefixes
    allowed_principals
    app_target_id
    application_id
    ca_bundle_ref
    certificate_envelope
    credential
    credential_custody_mode
    credential_mode
    credentials
    desktop_allowed_principals
    host_header
    http_headers
    max_request_bytes
    max_response_bytes
    passphrase
    password
    path_prefixes
    principal_mappings
    principals
    private_key
    rdp.kdc_proxy_url
    rdp.kerberos_hostname
    quota
    recording
    request_headers
    requested_principals
    route
    route_id
    secret
    secret_payload
    screen
    screen_policy
    desktop_screen_policy
    ssh
    ssh_accounts
    ssh_allowed_principals
    ssh_certificate
    ssh_certificate_ttl_seconds
    ssh_principal_mappings
    target_host
    target_port
    sni
    tcp_target_id
    ticket
    tls
    tls_server_name
    token
    upstream_host
    upstream_port
    upstream_url
    url
  )
  @client_controlled_metadata_suffixes ~w(_credential _password _secret _ticket _token)
  @default_rdp_screen_policy %{
    "max_width" => 1920,
    "max_height" => 1080,
    "frame_rate" => 30,
    "bitrate_bps" => 8_000_000,
    "idle_seconds" => 900,
    "ttl_seconds" => 3600
  }
  @rdp_screen_policy_maxima %{
    "max_width" => 7680,
    "max_height" => 4320,
    "frame_rate" => 60,
    "bitrate_bps" => 100_000_000,
    "idle_seconds" => 3600,
    "ttl_seconds" => 14_400
  }
  @desktop_policy_metadata_fields [
    {"target_tls", ~w(target_tls tls_policy tls)},
    {"nla", ~w(nla nla_policy)},
    {"screen_policy", ~w(screen_policy screen)},
    {"redirection_policy", ~w(redirection_policy redirection)},
    {"approval_policy", ~w(approval_policy approval)}
  ]

  def create(conn, params) do
    case requested_create_protocol(params) do
      "rdp" -> create_rdp(conn, params)
      _protocol -> create_ssh(conn, params)
    end
  end

  @doc """
  Browser-safe SSH console options for a device (policy account names only).

  Does not return opaque principals, CA material, or private keys.
  """
  def ssh_options(conn, %{"device_uid" => device_uid}) do
    with :ok <- require_remote_access_ssh_enabled(),
         :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @remote_access_ssh_permission),
         :ok <- require_device_visible(conn, device_uid),
         {:ok, options} <-
           remote_access_session_manager().ssh_console_options(device_uid, scope: get_scope(conn)) do
      json(conn, %{data: options})
    else
      {:error, :remote_access_ssh_disabled} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", message: "SSH remote access is not enabled"})

      {:error, :unauthorized} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "unauthorized", message: "Authentication is required"})

      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "forbidden", message: "Remote access permission is required"})

      {:error, reason} when reason in [:device_not_found, :not_found] ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "device_not_found", message: "Device was not found"})

      {:error, other} ->
        {:error, other}
    end
  end

  def ssh_options(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid_request", message: "device_uid is required"})
  end

  defp requested_create_protocol(params) when is_map(params) do
    normalize_optional_string(Map.get(params, "protocol")) ||
      if normalize_optional_string(Map.get(params, "desktop_target_id") || Map.get(params, "target_id")) do
        "rdp"
      else
        "ssh"
      end
  end

  defp requested_create_protocol(_params), do: "ssh"

  defp create_ssh(conn, params) do
    with :ok <- require_remote_access_ssh_enabled(),
         :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @remote_access_ssh_permission),
         {:ok, request} <- normalize_create_request(params, get_scope(conn)),
         {:ok, %{session: %RemoteAccessSession{} = session, ticket: ticket}} <-
           remote_access_session_manager().request_open(request.device_uid, request, scope: get_scope(conn)) do
      conn
      |> put_status(:created)
      |> json(%{data: session_json(session, ticket)})
    else
      {:error, :invalid_request, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: message})

      {:error, :remote_access_ssh_disabled} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", message: "SSH remote access is not enabled"})

      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "forbidden", message: "Remote access permission is required"})

      {:error, :approval_required} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "approval_required", message: "Remote access approval is required"})

      {:error, :approval_denied} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "approval_denied", message: "Remote access approval was denied"})

      {:error, reason}
      when reason in [
             :approval_pending,
             :approval_not_found,
             :approval_expired,
             :approval_consumed,
             :approval_scope_mismatch
           ] ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: Atom.to_string(reason), message: format_reason(reason)})

      {:error, :approval_checker_required} ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          error: "approval_checker_required",
          message: "Remote access approval must be verified before a session can start"
        })

      {:error, reason} when reason in [:device_not_found, :not_found] ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "remote_access_session_not_found", message: "remote access target was not found"})

      {:error, reason}
      when reason in [
             :missing_agent_scope,
             :missing_remote_access_target,
             :remote_access_target_disabled,
             :unsupported_remote_access_protocol,
             :unsupported_remote_access_adapter,
             :unsupported_remote_access_target,
             :unsupported_credential_custody_mode,
             :ssh_principal_policy_required,
             :credential_rule_required,
             :credential_rule_not_found,
             :credential_rule_disabled,
             :credential_rule_protocol_mismatch,
             :credential_rule_purpose_mismatch,
             :credential_rule_scope_mismatch
           ] ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "remote_access_session_unavailable", message: format_reason(reason)})

      {:error, other} ->
        {:error, other}
    end
  end

  defp create_rdp(conn, params) do
    with :ok <- require_remote_access_desktop_rdp_enabled(),
         :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @remote_access_rdp_permission),
         {:ok, request} <- normalize_rdp_create_request(params, get_scope(conn)),
         {:ok, %{session: %RemoteAccessSession{} = session, ticket: ticket}} <-
           remote_access_session_manager().request_open(request.device_uid, request, scope: get_scope(conn)) do
      conn
      |> put_status(:created)
      |> json(%{data: session_json(session, ticket)})
    else
      {:error, :invalid_request, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: message})

      {:error, :remote_access_desktop_rdp_disabled} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", message: "RDP remote access is not enabled"})

      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "forbidden", message: "RDP remote access permission is required"})

      {:error, :remote_access_desktop_target_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "remote_access_desktop_target_not_found", message: "RDP desktop target was not found"})

      {:error, :approval_required} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "approval_required", message: "Remote access approval is required"})

      {:error, :approval_denied} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "approval_denied", message: "Remote access approval was denied"})

      {:error, reason}
      when reason in [
             :approval_pending,
             :approval_not_found,
             :approval_expired,
             :approval_consumed,
             :approval_scope_mismatch
           ] ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: Atom.to_string(reason), message: format_reason(reason)})

      {:error, :approval_checker_required} ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          error: "approval_checker_required",
          message: "Remote access approval must be verified before a session can start"
        })

      {:error, reason} when reason in [:device_not_found, :not_found] ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "remote_access_session_not_found", message: "remote access target was not found"})

      {:error, reason}
      when reason in [
             :missing_agent_scope,
             :missing_remote_access_target,
             :unsupported_remote_access_protocol,
             :unsupported_remote_access_adapter,
             :unsupported_remote_access_target,
             :unsupported_credential_custody_mode,
             :credential_rule_required,
             :credential_rule_not_found,
             :credential_rule_disabled,
             :credential_rule_protocol_mismatch,
             :credential_rule_purpose_mismatch,
             :credential_rule_scope_mismatch
           ] ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "remote_access_session_unavailable", message: format_reason(reason)})

      {:error, other} ->
        {:error, other}
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- require_authenticated(conn),
         {:ok, normalized_id} <- normalize_uuid(id, "id"),
         {:ok, %RemoteAccessSession{} = session} <-
           remote_access_session_fetcher().(normalized_id, scope: get_scope(conn)),
         :ok <- require_session_owner(get_scope(conn), session),
         :ok <- require_session_permission(conn, session) do
      json(conn, %{data: session_json(session)})
    else
      {:error, :invalid_request, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: message})

      {:ok, nil} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "remote_access_session_not_found", message: "remote access session was not found"})

      {:error, %NotFound{}} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "remote_access_session_not_found", message: "remote access session was not found"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "remote_access_session_not_found", message: "remote access session was not found"})

      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "forbidden", message: "Remote access permission is required"})

      {:error, other} ->
        {:error, other}
    end
  end

  def close(conn, %{"id" => id} = params) do
    with :ok <- require_authenticated(conn),
         {:ok, normalized_id} <- normalize_uuid(id, "id"),
         {:ok, %RemoteAccessSession{} = authorized_session} <-
           remote_access_session_fetcher().(normalized_id, scope: get_scope(conn)),
         :ok <- require_session_owner(get_scope(conn), authorized_session),
         :ok <- require_session_permission(conn, authorized_session),
         {:ok, %RemoteAccessSession{} = session} <-
           remote_access_session_manager().request_close(normalized_id,
             reason: normalize_optional_string(Map.get(params, "reason")),
             scope: get_scope(conn)
           ),
         :ok <-
           close_desktop_viewers(
             authorized_session,
             get_scope(conn),
             normalize_optional_string(Map.get(params, "reason")) || "operator_requested"
           ) do
      json(conn, %{data: session_json(session)})
    else
      {:error, :invalid_request, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: message})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "remote_access_session_not_found", message: "remote access session was not found"})

      {:ok, nil} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "remote_access_session_not_found", message: "remote access session was not found"})

      {:error, %NotFound{}} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "remote_access_session_not_found", message: "remote access session was not found"})

      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "forbidden", message: "Remote access permission is required"})

      {:error, other} ->
        {:error, other}
    end
  end

  defp normalize_create_request(params, scope) when is_map(params) do
    metadata = normalize_metadata(Map.get(params, "metadata"))
    raw_ssh_host_key_policy = Map.get(params, "ssh_host_key_policy", metadata_value(metadata, "ssh_host_key_policy"))
    target_host = normalize_optional_string(Map.get(params, "target_host"))

    with {:ok, device_uid} <- normalize_required_string(Map.get(params, "device_uid"), "device_uid"),
         :ok <- validate_public_ssh_request(params),
         :ok <- validate_browser_route_selection(params),
         :ok <- validate_browser_policy_selection(params),
         :ok <- validate_browser_credential_rule_selection(params),
         {:ok, credential_custody_mode} <-
           normalize_public_ssh_custody_mode(Map.get(params, "credential_custody_mode")),
         :ok <- validate_target_host_override(target_host, scope),
         {:ok, target_port} <- normalize_target_port(Map.get(params, "target_port"), scope),
         {:ok, terminal} <- normalize_terminal(Map.get(params, "terminal")),
         {:ok, approval_id} <- normalize_optional_uuid(Map.get(params, "approval_id"), "approval_id"),
         {:ok, ssh_host_key_policy} <- normalize_ssh_host_key_policy(raw_ssh_host_key_policy) do
      metadata =
        metadata
        |> drop_metadata_key("ssh_host_key_policy")
        |> drop_client_controlled_metadata()
        |> put_optional("ssh_host_key_policy", ssh_host_key_policy)

      {:ok,
       %{
         device_uid: device_uid,
         protocol: "ssh",
         adapter: "ssh",
         target_kind: "inventory_device",
         target_host: target_host,
         target_port: target_port,
         agent_id: nil,
         gateway_id: nil,
         credential_custody_mode: credential_custody_mode,
         credential_rule_id: nil,
         approval_required: Map.get(params, "approval_required"),
         approval_id: approval_id,
         cols: terminal.cols,
         rows: terminal.rows,
         metadata: metadata,
         recording_policy: %{},
         enhanced_recording_policy: %{}
       }}
    end
  end

  defp normalize_create_request(_params, _scope), do: {:error, :invalid_request, "request body is required"}

  defp normalize_rdp_create_request(params, scope) when is_map(params) do
    metadata = normalize_metadata(Map.get(params, "metadata"))

    with {:ok, launch_device_uid} <-
           normalize_required_string(Map.get(params, "device_uid"), "device_uid"),
         {:ok, desktop_target_id} <-
           normalize_required_string(
             Map.get(params, "desktop_target_id") || Map.get(params, "target_id"),
             "desktop_target_id"
           ),
         :ok <- validate_optional_string_value(Map.get(params, "protocol"), "rdp", "protocol"),
         :ok <- validate_optional_string_value(Map.get(params, "adapter"), "rdp", "adapter"),
         :ok <- validate_rdp_browser_policy_selection(params),
         :ok <- require_visible_device(scope, launch_device_uid),
         {:ok, target} <- RemoteAccessDesktopTargets.get_authorized(scope, desktop_target_id),
         {:ok, device_uid} <- target_required_string(target, "device_uid"),
         :ok <- require_exact_rdp_device(launch_device_uid, device_uid),
         {:ok, target_host} <- target_required_string(target, "target_host"),
         {:ok, target_port} <- target_required_integer(target, "target_port"),
         {:ok, approval_id} <- normalize_optional_uuid(Map.get(params, "approval_id"), "approval_id") do
      desktop_policy = Map.get(target, "desktop_policy", %{})

      {:ok,
       %{
         device_uid: device_uid,
         protocol: "rdp",
         adapter: "rdp",
         target_kind: Map.get(target, "target_kind", "inventory_device"),
         target_host: target_host,
         target_port: target_port,
         agent_id: get_in(target, ["route", "agent_id"]),
         gateway_id: get_in(target, ["route", "gateway_id"]),
         credential_custody_mode: Map.get(target, "credential_custody_mode", "user_present"),
         credential_rule_id: Map.get(target, "credential_rule_id"),
         approval_required: Map.get(target, "approval_required"),
         approval_id: approval_id,
         cols: nil,
         rows: nil,
         metadata: rdp_target_metadata(desktop_target_id, target, desktop_policy, metadata),
         recording_policy: Map.get(target, "recording_policy", %{}),
         enhanced_recording_policy: %{}
       }}
    end
  end

  defp normalize_rdp_create_request(_params, _scope), do: {:error, :invalid_request, "request body is required"}

  defp validate_rdp_browser_policy_selection(params) do
    with :ok <- validate_browser_route_selection(params),
         :ok <- reject_browser_supplied_policy(Map.get(params, "recording_policy"), "recording_policy"),
         :ok <- reject_browser_supplied_policy(Map.get(params, "enhanced_recording_policy"), "enhanced_recording_policy"),
         :ok <- validate_browser_credential_rule_selection(params),
         :ok <- reject_browser_supplied_value(Map.get(params, "credential_custody_mode"), "credential_custody_mode"),
         :ok <- reject_browser_supplied_value(Map.get(params, "target_host"), "target_host") do
      reject_browser_supplied_value(Map.get(params, "target_port"), "target_port")
    end
  end

  defp reject_browser_supplied_value(nil, _field_name), do: :ok
  defp reject_browser_supplied_value("", _field_name), do: :ok

  defp reject_browser_supplied_value(_value, field_name),
    do: {:error, :invalid_request, "#{field_name} is selected by remote-access policy"}

  defp target_required_string(target, key) do
    case Map.get(target, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, :invalid_request, "desktop target #{key} is required"}
    end
  end

  defp target_required_integer(target, key) do
    case Map.get(target, key) do
      value when is_integer(value) -> {:ok, value}
      _value -> {:error, :invalid_request, "desktop target #{key} is required"}
    end
  end

  defp rdp_target_metadata(desktop_target_id, target, desktop_policy, browser_metadata) do
    target_metadata = Map.get(target, "metadata", %{})

    target_metadata
    |> Map.merge(drop_client_controlled_metadata(browser_metadata))
    |> Map.put("desktop_target_id", desktop_target_id)
    |> Map.put("desktop_allowed_principals", Map.get(target, "allowed_principals", []))
    |> put_optional("target_display_name", Map.get(target, "label"))
    |> put_optional("target_tls", Map.get(desktop_policy, "target_tls"))
    |> put_optional("nla", Map.get(desktop_policy, "nla"))
    |> Map.put(
      "screen_policy",
      effective_rdp_screen_policy(Map.get(desktop_policy, "screen_policy", %{}))
    )
    |> put_optional("redirection_policy", Map.get(desktop_policy, "redirection_policy"))
    |> put_optional("approval_policy", Map.get(desktop_policy, "approval_policy"))
  end

  defp effective_rdp_screen_policy(policy) when is_map(policy) do
    Enum.reduce(@default_rdp_screen_policy, %{}, fn {key, default}, bounded ->
      value = metadata_value(policy, key)
      maximum = Map.fetch!(@rdp_screen_policy_maxima, key)

      Map.put(bounded, key, bounded_positive_integer(value, default, maximum))
    end)
  end

  defp effective_rdp_screen_policy(_policy), do: @default_rdp_screen_policy

  defp bounded_positive_integer(value, _default, maximum) when is_integer(value) and value > 0, do: min(value, maximum)

  defp bounded_positive_integer(_value, default, _maximum), do: default

  defp require_exact_rdp_device(device_uid, device_uid), do: :ok

  defp require_exact_rdp_device(_requested_device_uid, _target_device_uid),
    do: {:error, :remote_access_desktop_target_not_found}

  defp require_visible_device(scope, device_uid) do
    case remote_access_device_visibility_fetcher().(device_uid, scope: scope) do
      {:ok, %Device{uid: ^device_uid}} -> :ok
      {:ok, nil} -> {:error, :remote_access_desktop_target_not_found}
      {:error, %NotFound{}} -> {:error, :remote_access_desktop_target_not_found}
      {:error, _error} -> {:error, :remote_access_desktop_target_not_found}
      _unexpected -> {:error, :remote_access_desktop_target_not_found}
    end
  end

  defp validate_public_ssh_request(params) do
    with :ok <- validate_optional_string_value(Map.get(params, "protocol"), "ssh", "protocol"),
         :ok <- validate_optional_string_value(Map.get(params, "adapter"), "ssh", "adapter") do
      validate_optional_string_value(Map.get(params, "target_kind"), "inventory_device", "target_kind")
    end
  end

  defp validate_optional_string_value(value, allowed_value, field_name) do
    case normalize_optional_string(value) do
      nil -> :ok
      ^allowed_value -> :ok
      _other -> {:error, :invalid_request, "#{field_name} is not supported by this endpoint"}
    end
  end

  defp validate_browser_route_selection(params) do
    with :ok <- reject_browser_supplied_route_value(Map.get(params, "agent_id"), "agent_id") do
      reject_browser_supplied_route_value(Map.get(params, "gateway_id"), "gateway_id")
    end
  end

  defp reject_browser_supplied_route_value(value, field_name) do
    case normalize_optional_string(value) do
      nil -> :ok
      _route_value -> {:error, :invalid_request, "#{field_name} is selected by inventory policy"}
    end
  end

  defp validate_browser_policy_selection(params) do
    with :ok <- reject_browser_supplied_policy(Map.get(params, "recording_policy"), "recording_policy") do
      reject_browser_supplied_policy(Map.get(params, "enhanced_recording_policy"), "enhanced_recording_policy")
    end
  end

  defp reject_browser_supplied_policy(nil, _field_name), do: :ok
  defp reject_browser_supplied_policy(value, _field_name) when value == %{}, do: :ok

  defp reject_browser_supplied_policy(_value, field_name),
    do: {:error, :invalid_request, "#{field_name} is selected by remote-access policy"}

  defp validate_browser_credential_rule_selection(params) do
    case normalize_optional_string(Map.get(params, "credential_rule_id")) do
      nil -> :ok
      _credential_rule_id -> {:error, :invalid_request, "credential_rule_id is selected by remote-access policy"}
    end
  end

  defp normalize_public_ssh_custody_mode(value) do
    case normalize_optional_string(value) do
      nil ->
        {:ok, nil}

      mode when mode in @browser_selectable_ssh_custody_modes ->
        {:ok, mode}

      _mode ->
        {:error, :invalid_request, "credential_custody_mode is selected by remote-access policy"}
    end
  end

  defp validate_target_host_override(nil, _scope), do: :ok

  defp validate_target_host_override(target_host, scope) do
    with :ok <- require_target_host_override_enabled(),
         :ok <- require_ssh_target_override_permission(scope) do
      if target_host_override_allowlisted?(target_host) do
        :ok
      else
        {:error, :invalid_request, "target_host override is not allowlisted"}
      end
    end
  end

  defp normalize_target_port(nil, _scope), do: {:ok, nil}

  defp normalize_target_port(value, scope) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      _present -> normalize_present_target_port(value, scope)
    end
  end

  defp normalize_target_port(value, scope), do: normalize_present_target_port(value, scope)

  defp normalize_present_target_port(value, scope) do
    with :ok <- require_target_port_override_enabled(),
         :ok <- require_ssh_target_override_permission(scope) do
      normalize_integer(value, "target_port", @min_target_port, @max_target_port)
    end
  end

  defp require_target_host_override_enabled do
    if Application.get_env(:serviceradar_web_ng, :remote_access_target_host_override_enabled, false) == true do
      :ok
    else
      {:error, :invalid_request, "target_host override is not enabled"}
    end
  end

  defp require_target_port_override_enabled do
    if Application.get_env(:serviceradar_web_ng, :remote_access_target_port_override_enabled, false) == true do
      :ok
    else
      {:error, :invalid_request, "target_port override is not enabled"}
    end
  end

  defp require_ssh_target_override_permission(scope) do
    if RBAC.can?(scope, @remote_access_ssh_target_override_permission), do: :ok, else: {:error, :forbidden}
  end

  defp target_host_override_allowlisted?(target_host) do
    normalized_host = normalize_allowlist_host(target_host)

    :serviceradar_web_ng
    |> Application.get_env(:remote_access_target_host_override_allowlist, [])
    |> configured_host_allowlist()
    |> Enum.any?(&host_allowlist_match?(normalized_host, &1))
  end

  defp configured_host_allowlist(value) when is_binary(value), do: String.split(value, ",", trim: true)
  defp configured_host_allowlist(value) when is_list(value), do: value
  defp configured_host_allowlist(_value), do: []

  defp host_allowlist_match?(nil, _entry), do: false

  defp host_allowlist_match?(host, entry) when is_binary(entry) do
    entry = normalize_allowlist_host(entry)

    cond do
      is_nil(entry) ->
        false

      String.starts_with?(entry, "*.") ->
        suffix = String.replace_prefix(entry, "*", "")
        String.ends_with?(host, suffix) and host != String.trim_leading(suffix, ".")

      true ->
        host == entry
    end
  end

  defp host_allowlist_match?(_host, _entry), do: false

  defp normalize_allowlist_host(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.trim_trailing(".")
      |> String.downcase()

    if normalized == "", do: nil, else: normalized
  end

  defp normalize_allowlist_host(_value), do: nil

  defp normalize_terminal(nil), do: {:ok, %{cols: nil, rows: nil}}

  defp normalize_terminal(value) when is_map(value) do
    with {:ok, cols} <-
           normalize_optional_integer(
             Map.get(value, "cols") || Map.get(value, :cols),
             "terminal.cols",
             @min_terminal_cols,
             @max_terminal_cols
           ),
         {:ok, rows} <-
           normalize_optional_integer(
             Map.get(value, "rows") || Map.get(value, :rows),
             "terminal.rows",
             @min_terminal_rows,
             @max_terminal_rows
           ) do
      {:ok, %{cols: cols, rows: rows}}
    end
  end

  defp normalize_terminal(_value), do: {:error, :invalid_request, "terminal must be an object"}

  defp normalize_uuid(value, field_name) when is_binary(value) do
    trimmed = String.trim(value)

    case Ecto.UUID.cast(trimmed) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_request, "#{field_name} must be a valid UUID"}
    end
  end

  defp normalize_uuid(_value, field_name), do: {:error, :invalid_request, "#{field_name} is required"}

  defp normalize_optional_uuid(nil, _field_name), do: {:ok, nil}

  defp normalize_optional_uuid(value, field_name) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      trimmed -> normalize_uuid(trimmed, field_name)
    end
  end

  defp normalize_optional_uuid(_value, field_name), do: {:error, :invalid_request, "#{field_name} must be a valid UUID"}

  defp normalize_required_string(value, field_name) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_request, "#{field_name} is required"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_required_string(_value, field_name), do: {:error, :invalid_request, "#{field_name} is required"}

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(_value), do: nil

  defp normalize_optional_integer(nil, _field_name, _min, _max), do: {:ok, nil}

  defp normalize_optional_integer(value, field_name, min, max) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      _present -> normalize_integer(value, field_name, min, max)
    end
  end

  defp normalize_optional_integer(value, field_name, min, max), do: normalize_integer(value, field_name, min, max)

  defp normalize_integer(value, field_name, min, max) when is_integer(value) do
    if value >= min and value <= max do
      {:ok, value}
    else
      {:error, :invalid_request, "#{field_name} must be between #{min} and #{max}"}
    end
  end

  defp normalize_integer(value, field_name, min, max) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> normalize_integer(int, field_name, min, max)
      _error -> {:error, :invalid_request, "#{field_name} must be an integer"}
    end
  end

  defp normalize_integer(_value, field_name, _min, _max),
    do: {:error, :invalid_request, "#{field_name} must be an integer"}

  defp normalize_ssh_host_key_policy(nil), do: {:ok, nil}

  defp normalize_ssh_host_key_policy(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      policy -> validate_ssh_host_key_policy(policy)
    end
  end

  defp normalize_ssh_host_key_policy(_value), do: {:error, :invalid_request, "ssh_host_key_policy is not supported"}

  defp validate_ssh_host_key_policy(policy) do
    if policy in allowed_ssh_host_key_policies() do
      {:ok, policy}
    else
      {:error, :invalid_request, "ssh_host_key_policy is not supported"}
    end
  end

  defp allowed_ssh_host_key_policies do
    if Application.get_env(
         :serviceradar_web_ng,
         :remote_access_ssh_host_key_skip_verify_enabled,
         false
       ) == true do
      @base_ssh_host_key_policies ++ ["skip_verify"]
    else
      @base_ssh_host_key_policies
    end
  end

  defp normalize_metadata(value) when is_map(value), do: value
  defp normalize_metadata(_value), do: %{}

  defp metadata_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      case safe_existing_atom(key) do
        nil -> nil
        atom_key -> Map.get(map, atom_key)
      end
  end

  defp metadata_value(_map, _key), do: nil

  defp drop_metadata_key(map, "ssh_host_key_policy") do
    map
    |> Map.delete("ssh_host_key_policy")
    |> Map.delete(:ssh_host_key_policy)
  end

  defp drop_metadata_key(map, key) when is_binary(key) do
    map
    |> Map.delete(key)
    |> then(fn map ->
      case safe_existing_atom(key) do
        nil -> map
        atom_key -> Map.delete(map, atom_key)
      end
    end)
  end

  defp drop_client_controlled_metadata(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      if client_controlled_metadata_key?(key) do
        acc
      else
        Map.put(acc, key, drop_client_controlled_metadata_value(value))
      end
    end)
  end

  defp drop_client_controlled_metadata_value(value) when is_map(value), do: drop_client_controlled_metadata(value)

  defp drop_client_controlled_metadata_value(value) when is_list(value),
    do: Enum.map(value, &drop_client_controlled_metadata_value/1)

  defp drop_client_controlled_metadata_value(value), do: value

  defp client_controlled_metadata_key?(key) when is_atom(key), do: client_controlled_metadata_key?(Atom.to_string(key))

  defp client_controlled_metadata_key?(key) when is_binary(key) do
    normalized = String.downcase(key)

    normalized in @client_controlled_metadata_denylist or
      Enum.any?(@client_controlled_metadata_suffixes, &String.ends_with?(normalized, &1))
  end

  defp client_controlled_metadata_key?(_key), do: false

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp safe_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp session_json(session, ticket \\ nil) do
    data = %{
      id: session.id,
      device_uid: session.device_uid,
      target_kind: format_value(session.target_kind),
      target_host: session.target_host,
      target_port: session.target_port,
      protocol: format_value(session.protocol),
      adapter: format_value(session.adapter),
      agent_id: session.agent_id,
      gateway_id: session.gateway_id,
      credential_custody_mode: format_value(session.credential_custody_mode),
      credential_rule_id: session.credential_rule_id,
      approval_id: session.approval_id,
      rbac_decision: format_value(session.rbac_decision),
      status: format_value(session.status),
      outcome: format_value(session.outcome),
      attach_expires_at: format_value(session.attach_expires_at),
      idle_timeout_seconds: session.idle_timeout_seconds,
      absolute_timeout_seconds: session.absolute_timeout_seconds,
      websocket_path: "/v1/remote-access/sessions/#{session.id}/stream",
      close_reason: session.close_reason,
      failure_reason: session.failure_reason,
      inserted_at: format_value(session.inserted_at),
      updated_at: format_value(session.updated_at)
    }

    data =
      if format_value(session.protocol) == "rdp" do
        data
        |> Map.merge(RemoteDesktopWebRTC.metadata(session))
        |> Map.put(:desktop_policy_snapshot, desktop_policy_snapshot(session))
      else
        data
      end

    if is_binary(ticket), do: Map.put(data, :ticket, ticket), else: data
  end

  defp format_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value), do: value

  defp desktop_policy_snapshot(%RemoteAccessSession{} = session) do
    metadata = normalize_metadata(session.metadata)

    reject_empty(%{
      target:
        reject_empty(%{
          device_uid: session.device_uid,
          target_kind: format_value(session.target_kind),
          protocol: format_value(session.protocol),
          display_name: metadata_value(metadata, "target_display_name") || session.device_uid
        }),
      route: reject_empty(%{agent_id: session.agent_id, gateway_id: session.gateway_id}),
      credential:
        reject_empty(%{
          custody_mode: format_value(session.credential_custody_mode),
          brokered_rule_bound: not is_nil(session.credential_rule_id)
        }),
      authorization:
        reject_empty(%{rbac_decision: format_value(session.rbac_decision), approval_id: session.approval_id}),
      timeouts:
        reject_empty(%{
          idle_timeout_seconds: session.idle_timeout_seconds,
          absolute_timeout_seconds: session.absolute_timeout_seconds
        }),
      desktop: desktop_policy_metadata(metadata),
      recording: recording_policy_snapshot(session)
    })
  end

  defp desktop_policy_metadata(metadata) do
    @desktop_policy_metadata_fields
    |> Enum.reduce(%{}, fn {snapshot_key, metadata_keys}, acc ->
      case metadata |> first_metadata_value(metadata_keys) |> sanitize_snapshot_value() |> reject_empty() do
        nil -> acc
        value -> Map.put(acc, snapshot_key, value)
      end
    end)
    |> reject_empty()
  end

  defp first_metadata_value(metadata, keys) do
    Enum.find_value(keys, &metadata_value(metadata, &1))
  end

  defp recording_policy_snapshot(%RemoteAccessSession{} = session) do
    reject_empty(%{
      policy: session.recording_policy |> sanitize_snapshot_value() |> reject_empty(),
      enhanced_policy: session.enhanced_recording_policy |> sanitize_snapshot_value() |> reject_empty()
    })
  end

  defp sanitize_snapshot_value(%{} = value) do
    Enum.reduce(value, %{}, fn {key, nested_value}, acc ->
      if sensitive_metadata_key?(key) do
        acc
      else
        sanitized_value = sanitize_snapshot_value(nested_value)

        case reject_empty(sanitized_value) do
          nil -> acc
          safe_value -> Map.put(acc, snapshot_key(key), safe_value)
        end
      end
    end)
  end

  defp sanitize_snapshot_value(value) when is_list(value), do: Enum.map(value, &sanitize_snapshot_value/1)
  defp sanitize_snapshot_value(value), do: value

  defp sensitive_metadata_key?(key) when is_atom(key), do: key |> Atom.to_string() |> sensitive_metadata_key?()

  defp sensitive_metadata_key?(key) when is_binary(key) do
    normalized = String.downcase(key)

    normalized in @client_controlled_metadata_denylist or
      Enum.any?(@client_controlled_metadata_suffixes, &String.ends_with?(normalized, &1))
  end

  defp sensitive_metadata_key?(_key), do: false

  defp snapshot_key(key) when is_atom(key), do: Atom.to_string(key)
  defp snapshot_key(key) when is_binary(key), do: key
  defp snapshot_key(key), do: to_string(key)

  defp reject_empty(%{} = map) do
    map
    |> Enum.reject(fn {_key, value} -> empty_snapshot_value?(value) end)
    |> Map.new()
    |> case do
      empty when map_size(empty) == 0 -> nil
      present -> present
    end
  end

  defp reject_empty(value), do: value

  defp empty_snapshot_value?(nil), do: true
  defp empty_snapshot_value?(%{} = map), do: map_size(map) == 0
  defp empty_snapshot_value?([]), do: true
  defp empty_snapshot_value?(_value), do: false

  defp format_reason(:missing_agent_scope), do: "target has no selected edge agent for remote-access routing"
  defp format_reason(:missing_remote_access_target), do: "target host could not be resolved for remote access"
  defp format_reason(:remote_access_target_disabled), do: "remote-access target is disabled"
  defp format_reason(:unsupported_remote_access_protocol), do: "requested remote-access protocol is not supported"
  defp format_reason(:unsupported_remote_access_adapter), do: "requested remote-access adapter is not supported"
  defp format_reason(:unsupported_remote_access_target), do: "requested remote-access target is not supported"
  defp format_reason(:unsupported_credential_custody_mode), do: "requested credential custody mode is not supported"

  defp format_reason(:ssh_principal_policy_required),
    do: "SSH certificate access requires trusted account and principal policy for the target"

  defp format_reason(:credential_rule_required), do: "centrally brokered remote access requires a trusted credential rule"

  defp format_reason(:credential_rule_not_found), do: "trusted credential rule was not found"
  defp format_reason(:credential_rule_disabled), do: "trusted credential rule is disabled"
  defp format_reason(:credential_rule_protocol_mismatch), do: "trusted credential rule does not match the protocol"
  defp format_reason(:credential_rule_purpose_mismatch), do: "trusted credential rule is not valid for remote access"
  defp format_reason(:credential_rule_scope_mismatch), do: "trusted credential rule does not match the selected route"
  defp format_reason(:approval_pending), do: "remote access approval is still pending"
  defp format_reason(:approval_not_found), do: "remote access approval was not found"
  defp format_reason(:approval_expired), do: "remote access approval has expired"
  defp format_reason(:approval_consumed), do: "remote access approval has already been used"
  defp format_reason(:approval_scope_mismatch), do: "remote access approval does not match the requested session"

  defp format_reason(reason), do: Atom.to_string(reason)

  defp remote_access_session_manager do
    Application.get_env(
      :serviceradar_web_ng,
      :remote_access_session_manager,
      ServiceRadar.Edge.RemoteAccessSessions
    )
  end

  defp remote_access_session_fetcher do
    Application.get_env(
      :serviceradar_web_ng,
      :remote_access_session_fetcher,
      fn session_id, opts -> RemoteAccessSession.get_by_id(session_id, opts) end
    )
  end

  defp remote_access_device_visibility_fetcher do
    Application.get_env(
      :serviceradar_web_ng,
      :remote_access_device_visibility_fetcher,
      fn device_uid, opts -> Device.get_by_uid(device_uid, false, opts) end
    )
  end

  defp require_device_visible(conn, device_uid) when is_binary(device_uid) do
    scope = get_scope(conn)

    case remote_access_device_visibility_fetcher().(device_uid, scope: scope) do
      {:ok, %Device{}} -> :ok
      {:ok, device} when is_map(device) and map_size(device) > 0 -> :ok
      {:ok, nil} -> {:error, :device_not_found}
      {:error, _} -> {:error, :device_not_found}
      _ -> {:error, :device_not_found}
    end
  end

  defp require_device_visible(_conn, _device_uid), do: {:error, :device_not_found}

  defp get_scope(conn), do: conn.assigns[:current_scope]

  defp require_remote_access_ssh_enabled do
    if FeatureFlags.remote_access_ssh_enabled?() do
      :ok
    else
      {:error, :remote_access_ssh_disabled}
    end
  end

  defp require_remote_access_desktop_rdp_enabled do
    if FeatureFlags.remote_access_desktop_rdp_enabled?() do
      :ok
    else
      {:error, :remote_access_desktop_rdp_disabled}
    end
  end

  defp require_authenticated(conn) do
    case conn.assigns[:current_scope] do
      %Scope{user: user} when not is_nil(user) -> :ok
      _ -> {:error, :unauthorized}
    end
  end

  defp require_permission(conn, permission) when is_binary(permission) do
    scope = conn.assigns[:current_scope]
    if RBAC.can?(scope, permission), do: :ok, else: {:error, :forbidden}
  end

  defp require_session_permission(conn, %RemoteAccessSession{} = session) do
    require_permission(conn, permission_for_session(session))
  end

  defp close_desktop_viewers(%RemoteAccessSession{} = session, scope, reason) do
    if format_value(session.protocol) == "rdp" do
      _ = RemoteDesktopWebRTC.close_all_for_session(session.id, scope: scope, reason: reason)
    end

    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp require_session_owner(scope, %RemoteAccessSession{requested_by: requested_by}) do
    with actor_id when is_binary(actor_id) <- scope_actor_id(scope),
         owner_id when is_binary(owner_id) <- normalize_id(requested_by),
         true <- actor_id == owner_id do
      :ok
    else
      _mismatch -> {:error, :not_found}
    end
  end

  defp scope_actor_id(%{user: %{id: id}}), do: normalize_id(id)
  defp scope_actor_id(_scope), do: nil

  defp normalize_id(id) when is_binary(id), do: id
  defp normalize_id(id) when not is_nil(id), do: to_string(id)
  defp normalize_id(_id), do: nil

  defp permission_for_session(%RemoteAccessSession{} = session) do
    case format_value(session.protocol) do
      "rdp" -> @remote_access_rdp_permission
      _protocol -> @remote_access_ssh_permission
    end
  end
end
