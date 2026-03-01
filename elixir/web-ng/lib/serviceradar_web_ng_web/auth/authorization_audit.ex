defmodule ServiceRadarWebNGWeb.AuthorizationAudit do
  @moduledoc """
  Audit logging for authorization events.

  This module provides structured logging for security-relevant authorization events,
  enabling compliance monitoring and security incident investigation.

  ## Logged Events

  - Authorization failures (policy denials)
  - Suspicious access patterns (multiple failures)
  - Partition isolation violations

  ## Log Format

  All events are logged as structured data compatible with centralized log aggregation:

      %{
        event_type: "authorization_failure",
        actor_id: "user-uuid",
        actor_email: "user@example.com",
        resource: "ServiceRadar.Infrastructure.Gateway",
        action: :read,
        request_path: "/api/v2/gateways",
        client_ip: "192.168.1.100",
        timestamp: ~U[2025-01-15 10:30:00Z],
        details: %{...}
      }

  ## Integration

  Used by:
  - FallbackController for API authorization errors
  - LiveView hooks for UI authorization errors
  - Ash policy error handlers
  """

  require Logger

  alias ServiceRadarWebNGWeb.ClientIP

  @doc """
  Log an authorization failure event.

  Takes a connection or socket and an Ash error, extracts relevant context,
  and logs a structured audit event.

  ## Examples

      iex> AuthorizationAudit.log_failure(conn, %Ash.Error.Forbidden{})
      :ok

      iex> AuthorizationAudit.log_failure(socket, %Ash.Error.Forbidden{})
      :ok
  """
  def log_failure(conn_or_socket, error, opts \\ [])

  def log_failure(%Plug.Conn{} = conn, error, opts) do
    event = build_event_from_conn(conn, error, opts)
    log_event(event)
  end

  def log_failure(%Phoenix.LiveView.Socket{} = socket, error, opts) do
    event = build_event_from_socket(socket, error, opts)
    log_event(event)
  end

  def log_failure(_context, error, opts) do
    # Fallback for cases without request context
    event = %{
      event_type: "authorization_failure",
      actor_id: Keyword.get(opts, :actor_id, "unknown"),
      resource: extract_resource(error),
      action: extract_action(error),
      timestamp: DateTime.utc_now(),
      details: %{
        error_type: error.__struct__ |> to_string() |> String.split(".") |> List.last()
      }
    }

    log_event(event)
  end

  @doc """
  Log a suspicious access pattern.

  Called when multiple authorization failures are detected from the same actor
  or IP address in a short time window.
  """
  def log_suspicious_pattern(actor_id, pattern_type, details \\ %{}) do
    event = %{
      event_type: "suspicious_access_pattern",
      actor_id: actor_id,
      pattern_type: pattern_type,
      timestamp: DateTime.utc_now(),
      details: details
    }

    Logger.warning(fn -> format_event(event) end,
      event_type: :security_audit,
      severity: :warning
    )
  end

  # Private functions

  defp build_event_from_conn(conn, error, opts) do
    actor = conn.assigns[:ash_actor] || conn.assigns[:current_scope]

    %{
      event_type: "authorization_failure",
      actor_id: get_actor_id(actor),
      actor_email: get_actor_email(actor),
      partition_id: conn.assigns[:current_partition_id],
      resource: extract_resource(error),
      action: Keyword.get(opts, :action) || extract_action(error),
      request_path: conn.request_path,
      request_method: conn.method,
      client_ip: get_client_ip(conn),
      timestamp: DateTime.utc_now(),
      details: %{
        error_type: error.__struct__ |> to_string() |> String.split(".") |> List.last()
      }
    }
  end

  defp build_event_from_socket(socket, error, opts) do
    actor = socket.assigns[:ash_actor] || socket.assigns[:current_scope]

    %{
      event_type: "authorization_failure",
      actor_id: get_actor_id(actor),
      actor_email: get_actor_email(actor),
      partition_id: socket.assigns[:current_partition_id],
      resource: extract_resource(error),
      action: Keyword.get(opts, :action) || extract_action(error),
      view: socket.view |> to_string(),
      timestamp: DateTime.utc_now(),
      details: %{
        error_type: error.__struct__ |> to_string() |> String.split(".") |> List.last()
      }
    }
  end

  defp get_actor_id(%{id: id}), do: id
  defp get_actor_id(%{user: %{id: id}}), do: id
  defp get_actor_id(_), do: "anonymous"

  defp get_actor_email(%{email: email}), do: email
  defp get_actor_email(%{user: %{email: email}}), do: email
  defp get_actor_email(_), do: nil

  defp get_client_ip(conn) do
    ClientIP.get(conn)
  end

  defp extract_resource(%{errors: [%{resource: resource} | _]}), do: inspect(resource)
  defp extract_resource(_), do: "unknown"

  defp extract_action(%{errors: [%{action: action} | _]}), do: action
  defp extract_action(_), do: :unknown

  defp log_event(event) do
    Logger.warning(fn -> format_event(event) end,
      event_type: :authorization_audit
    )

    :ok
  end

  defp format_event(event) do
    parts = [
      "Authorization audit:",
      "event=#{event.event_type}",
      "actor=#{event.actor_id}",
      "resource=#{event[:resource]}",
      "action=#{event[:action]}"
    ]

    parts =
      if event[:request_path] do
        parts ++ ["path=#{event.request_path}"]
      else
        parts
      end

    parts =
      if event[:client_ip] do
        parts ++ ["ip=#{event.client_ip}"]
      else
        parts
      end

    Enum.join(parts, " ")
  end
end
