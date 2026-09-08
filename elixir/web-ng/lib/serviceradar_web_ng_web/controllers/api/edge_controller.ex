defmodule ServiceRadarWebNGWeb.Api.EdgeController do
  @moduledoc """
  JSON API controller for edge onboarding operations.

  Provides REST endpoints for managing edge onboarding packages, matching
  the API contract from the Go serviceradar-core implementation.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Edge.OnboardingPackage
  alias ServiceRadar.Security.Events, as: SecurityEvents
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Edge.BundleGenerator
  alias ServiceRadarWebNG.Edge.ComponentTemplates
  alias ServiceRadarWebNG.Edge.GatewayCertificateIssuer
  alias ServiceRadarWebNG.Edge.OnboardingEvents
  alias ServiceRadarWebNG.Edge.OnboardingPackages
  alias ServiceRadarWebNG.Edge.OnboardingToken
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.ClientIP

  require Ash.Query
  require Logger

  action_fallback(ServiceRadarWebNGWeb.Api.FallbackController)

  @doc """
  GET /api/admin/edge-packages/defaults

  Returns default selectors and metadata for package creation.
  """
  def defaults(conn, _params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "settings.edge.manage") do
      defaults = OnboardingPackages.defaults()

      json(conn, %{
        selectors: defaults.selectors,
        metadata: defaults.metadata
      })
    end
  end

  @doc """
  GET /api/admin/edge-packages

  Lists edge onboarding packages with optional filters.

  Query params:
    - status: comma-separated list of statuses (e.g., "issued,delivered")
    - component_type: comma-separated list of types (e.g., "gateway,checker")
    - gateway_id: filter by gateway ID
    - component_id: filter by component ID
    - parent_id: filter by parent ID
    - limit: max results (default: 100)
  """
  def index(conn, params) do
    filters = build_filters(params)

    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "settings.edge.manage") do
      actor = get_user_actor(conn)
      packages = OnboardingPackages.list(filters, actor: actor)
      json(conn, Enum.map(packages, &package_to_json/1))
    end
  end

  @doc """
  POST /api/admin/edge-packages

  Creates a new edge onboarding package.
  """
  def create(conn, params) do
    actor = get_user_actor(conn)
    source_ip = ClientIP.get(conn)
    partition_id = request_partition_id(params)

    attrs = %{
      label: params["label"],
      component_id: params["component_id"] || params["gateway_id"],
      component_type: params["component_type"] || "gateway",
      parent_type: params["parent_type"],
      parent_id: params["parent_id"],
      gateway_id: params["gateway_id"],
      partition_id: partition_id,
      site: partition_id,
      security_mode: params["security_mode"] || "spire",
      selectors: params["selectors"] || [],
      checker_kind: params["checker_kind"],
      checker_config_json: params["checker_config_json"],
      metadata_json: params["metadata_json"],
      notes: params["notes"],
      created_by: actor,
      downstream_spiffe_id: params["downstream_spiffe_id"]
    }

    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "settings.edge.manage") do
      opts = [
        join_token_ttl_seconds: params["join_token_ttl_seconds"] || 86_400,
        download_token_ttl_seconds: params["download_token_ttl_seconds"] || 86_400,
        actor: actor,
        source_ip: source_ip
      ]

      case OnboardingPackages.create(attrs, opts) do
        {:ok, result} ->
          conn
          |> put_status(:created)
          |> json(%{
            package: package_to_json(result.package),
            join_token: result.join_token,
            download_token: result.download_token,
            bundle_pem: ""
          })

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  GET /api/admin/edge-packages/:id

  Gets a single package by ID.
  """
  def show(conn, %{"id" => id}) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "settings.edge.manage") do
      actor = get_user_actor(conn)

      case OnboardingPackages.get(id, actor: actor) do
        {:ok, package} ->
          json(conn, package_to_json(package))

        {:error, :not_found} ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  DELETE /api/admin/edge-packages/:id

  Soft-deletes a package.
  """
  def delete(conn, %{"id" => id}) do
    actor = get_user_actor(conn)
    source_ip = ClientIP.get(conn)

    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "settings.edge.manage") do
      opts = [actor: actor, source_ip: source_ip]

      case OnboardingPackages.delete(id, opts) do
        {:ok, _package} ->
          send_resp(conn, :no_content, "")

        {:error, :not_found} ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  GET /api/admin/edge-packages/:id/events

  Lists audit events for a package.
  """
  def events(conn, %{"id" => id} = params) do
    limit = parse_int(params["limit"]) || 50
    events_list(conn, id, limit)
  end

  defp events_list(conn, package_id, limit) do
    # First verify package exists
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "settings.edge.manage") do
      actor = get_user_actor(conn)

      case OnboardingPackages.get(package_id, actor: actor) do
        {:ok, _package} ->
          events = OnboardingEvents.list_for_package(package_id, actor: actor, limit: limit)
          json(conn, Enum.map(events, &event_to_json/1))

        {:error, :not_found} ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  POST /api/admin/edge-packages/:id/download

  Delivers a package to the client, returning tokens and certificates.
  Requires a valid download token in the request body.
  """
  def download(conn, %{"id" => id}) do
    download_token = extract_download_token(conn)
    source_ip = ClientIP.get(conn)
    route = "/api/admin/edge-packages/:id/download"

    if download_token in [nil, ""] do
      record_onboarding_audit({:failure, :missing_download_token}, id, source_ip, route)

      conn
      |> put_status(:bad_request)
      |> json(%{error: "download_token is required"})
    else
      actor = nil

      case download_with_token(id, download_token, source_ip, actor) do
        {:ok, result} ->
          record_onboarding_audit(:success, id, source_ip, route)
          json(conn, result)

        {:error, reason} ->
          record_onboarding_audit({:failure, reason}, id, source_ip, route)
          handle_download_error(conn, reason)
      end
    end
  end

  defp download_with_token(id, download_token, source_ip, actor) do
    with {:ok, package} <- find_package(id),
         {:ok, token_context} <- verified_download_token(package, id, download_token) do
      deliver_package(id, token_context.download_token, source_ip, actor || token_context.actor)
    end
  end

  defp deliver_package(id, download_token, source_ip, actor) do
    opts = [actor: actor, source_ip: source_ip, authorize?: true]

    case OnboardingPackages.deliver(id, download_token, opts) do
      {:ok, result} ->
        {:ok,
         %{
           package: package_to_json(result.package),
           join_token: result.join_token,
           bundle_pem: result.bundle_pem || ""
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_download_error(conn, :invalid_token) do
    conn |> put_status(:unauthorized) |> json(%{error: "download token invalid"})
  end

  defp handle_download_error(conn, :expired) do
    conn |> put_status(:gone) |> json(%{error: "download token expired"})
  end

  defp handle_download_error(conn, :not_found) do
    conn |> put_status(:not_found) |> json(%{error: "package not found"})
  end

  defp handle_download_error(conn, reason)
       when reason in [
              :unsupported_token_format,
              :invalid_signature,
              :invalid_base64,
              :invalid_json,
              :invalid_public_key,
              :invalid_key,
              :malformed_token,
              :missing_signing_key,
              :missing_partition_id,
              :partition_mismatch,
              :package_mismatch
            ] do
    conn |> put_status(:unauthorized) |> json(%{error: "onboarding token invalid"})
  end

  defp handle_download_error(conn, reason) when reason in [:already_delivered, :revoked, :deleted] do
    conn |> put_status(:conflict) |> json(%{error: "package #{reason}"})
  end

  defp handle_bundle_error(conn, {:bundle_error, reason}) do
    Logger.error("Edge bundle generation failed: #{inspect(reason)}")

    conn
    |> put_status(:internal_server_error)
    |> json(%{error: "bundle_generation_failed"})
  end

  defp handle_bundle_error(conn, reason)
       when reason in [
              :invalid_token,
              :expired,
              :not_found,
              :already_delivered,
              :revoked,
              :deleted,
              :unsupported_token_format,
              :invalid_signature,
              :invalid_base64,
              :invalid_json,
              :invalid_public_key,
              :invalid_key,
              :malformed_token,
              :missing_signing_key,
              :missing_partition_id,
              :partition_mismatch,
              :package_mismatch
            ] do
    handle_download_error(conn, reason)
  end

  defp handle_bundle_error(conn, reason) do
    Logger.error("Edge bundle request failed: #{inspect(reason)}")

    conn
    |> put_status(:internal_server_error)
    |> json(%{error: "bundle_request_failed"})
  end

  @doc """
  POST /api/edge-packages/:id/bundle

  Downloads the package as a tarball containing certificates, config, and install script.
  Requires a valid download token in the `x-serviceradar-download-token` header or request body.

  Request fields:
    - x-serviceradar-download-token header, or
    - download_token: the download token (required)

  Returns: application/gzip tarball
  """
  def bundle(conn, %{"id" => id}) do
    download_token = extract_download_token(conn)
    source_ip = ClientIP.get(conn)
    base_url = ServiceRadarWebNGWeb.Endpoint.url()
    route = "/api/edge-packages/:id/bundle"

    if download_token in [nil, ""] do
      record_onboarding_audit({:failure, :missing_download_token}, id, source_ip, route)

      conn
      |> put_status(:bad_request)
      |> json(%{error: "download token is required"})
    else
      case bundle_with_token(id, download_token, source_ip, base_url) do
        {:ok, tarball, filename} ->
          record_onboarding_audit(:success, id, source_ip, route)

          conn
          |> put_resp_content_type("application/gzip")
          |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
          |> send_resp(200, tarball)

        {:error, reason} ->
          record_onboarding_audit({:failure, reason}, id, source_ip, route)
          handle_bundle_error(conn, reason)
      end
    end
  end

  defp extract_download_token(conn) do
    header_download_token(conn) ||
      body_download_token(conn, "onboarding_token") ||
      body_download_token(conn, "download_token")
  end

  defp normalize_download_token(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_download_token(_value), do: nil

  defp bundle_with_token(id, download_token, source_ip, base_url) do
    with {:ok, package} <- find_package(id),
         {:ok, token_context} <- verified_download_token(package, id, download_token),
         {:ok,
          %{
            package: package,
            join_token: join_token,
            bundle_pem: bundle_pem
          }} <-
           OnboardingPackages.deliver(id, token_context.download_token,
             actor: token_context.actor,
             source_ip: source_ip,
             authorize?: true
           ),
         {:ok, tarball} <-
           wrap_bundle_error(
             bundle_generator().create_tarball(package, bundle_pem || "", join_token,
               download_token: token_context.download_token,
               base_url: base_url
             )
           ) do
      filename = BundleGenerator.bundle_filename(package)
      {:ok, tarball, filename}
    end
  end

  defp wrap_bundle_error({:ok, tarball}), do: {:ok, tarball}
  defp wrap_bundle_error({:error, reason}), do: {:error, {:bundle_error, reason}}

  defp bundle_generator do
    case Application.get_env(:serviceradar_web_ng, :edge_bundle_generator) do
      module when is_atom(module) and not is_nil(module) -> module
      _ -> BundleGenerator
    end
  end

  defp body_param(conn, key) when is_binary(key) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> nil
      body when is_map(body) -> Map.get(body, key)
      _ -> nil
    end
  end

  defp header_download_token(conn) do
    conn
    |> Plug.Conn.get_req_header("x-serviceradar-download-token")
    |> List.first()
    |> normalize_download_token()
  end

  defp body_download_token(conn, key) do
    conn |> body_param(key) |> normalize_download_token()
  end

  defp verified_download_token(package, package_id, raw_token) do
    with {:ok, payload} <- OnboardingToken.decode(raw_token),
         :ok <- verify_onboarding_token_package(payload, package_id),
         :ok <- verify_onboarding_token_partition(payload, package) do
      {:ok,
       %{
         download_token: payload.dl,
         actor: onboarding_token_actor(payload)
       }}
    end
  end

  # Emit a structured audit event (surfaced at /settings/audit/events) and a log line for
  # every edge-onboarding bundle/download attempt — success and failure — so operators can
  # see when an agent enrolls and exactly why an attempt was rejected.
  defp record_onboarding_audit(outcome, package_id, source_ip, route) do
    {kind, severity, reason} =
      case outcome do
        :success -> {:edge_onboarding_succeeded, :info, nil}
        {:failure, reason} -> {:edge_onboarding_failed, :warning, reason}
      end

    ip = source_ip || "unknown"

    if is_nil(reason) do
      Logger.info("edge onboarding bundle delivered package_id=#{package_id} ip=#{ip} route=#{route}")
    else
      Logger.warning(
        "edge onboarding attempt failed package_id=#{package_id} ip=#{ip} route=#{route} reason=#{inspect(reason)}"
      )
    end

    details =
      if is_nil(reason) do
        %{package_id: package_id}
      else
        %{package_id: package_id, reason: inspect(reason)}
      end

    SecurityEvents.record(%{
      kind: kind,
      severity: severity,
      ip: source_ip,
      route: route,
      details: details
    })

    :ok
  end

  defp onboarding_token_actor(%{pkg: package_id, partition_id: partition_id}) do
    normalized_partition_id = normalize_partition_id(partition_id)

    %{
      id: "edge-onboarding-token:#{package_id}",
      email: "edge-onboarding-token@serviceradar.local",
      role: :operator,
      partition_id: normalized_partition_id
    }
  end

  defp verify_onboarding_token_package(%{pkg: token_package_id}, package_id) when token_package_id == package_id, do: :ok

  defp verify_onboarding_token_package(_payload, _package_id), do: {:error, :package_mismatch}

  defp verify_onboarding_token_partition(%{partition_id: partition_id}, package) when is_binary(partition_id) do
    if normalize_partition_id(partition_id) == package_partition_id(package) do
      :ok
    else
      {:error, :partition_mismatch}
    end
  end

  defp verify_onboarding_token_partition(_payload, _package), do: {:error, :missing_partition_id}

  defp package_partition_id(%{partition_id: partition_id}) when is_binary(partition_id) do
    normalize_partition_id(partition_id)
  end

  defp package_partition_id(%{site: site}), do: normalize_partition_id(site)

  defp request_partition_id(params) do
    normalize_partition_id(params["partition_id"] || params["site"])
  end

  defp normalize_partition_id(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: "default", else: value
  end

  defp normalize_partition_id(_value), do: "default"

  @doc """
  POST /api/admin/edge-packages/:id/revoke

  Revokes a package, preventing further delivery.
  """
  def revoke(conn, %{"id" => id} = params) do
    actor = get_user_actor(conn)
    source_ip = ClientIP.get(conn)
    reason = params["reason"]

    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "settings.edge.manage") do
      opts = [actor: actor, source_ip: source_ip, reason: reason]

      case OnboardingPackages.revoke(id, opts) do
        {:ok, package} ->
          json(conn, package_to_json(package))

        {:error, :not_found} ->
          {:error, :not_found}

        {:error, :already_revoked} ->
          conn
          |> put_status(:conflict)
          |> json(%{error: "package already revoked"})
      end
    end
  end

  @doc """
  POST /api/admin/gateways/:gateway_id/agent-certs/:component_id/revoke

  Revokes an agent mTLS certificate by component id on the selected gateway.
  """
  def revoke_agent_certificate(conn, %{"gateway_id" => gateway_id, "component_id" => component_id} = params) do
    reason = params["reason"]

    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "settings.edge.manage") do
      case GatewayCertificateIssuer.revoke_agent_certificate(gateway_id, component_id, reason: reason) do
        {:ok, result} ->
          json(conn, result)

        {:error, :gateway_unavailable} ->
          conn
          |> put_status(:service_unavailable)
          |> json(%{error: "gateway unavailable"})

        {:error, :invalid_identity} ->
          conn
          |> put_status(:bad_request)
          |> json(%{error: "invalid identity"})
      end
    end
  end

  @doc """
  GET /api/admin/component-templates

  Lists available component templates from KV store.

  Query params:
    - component_type: filter by component type (e.g., "checker", "gateway")
    - security_mode: filter by security mode (e.g., "mtls", "insecure")

  If both filters are provided, returns templates matching both criteria.
  If no filters provided, returns templates for all known combinations.
  """
  def templates(conn, params) do
    component_type = params["component_type"]
    security_mode = params["security_mode"]

    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "settings.edge.manage") do
      templates = list_templates(component_type, security_mode)
      json(conn, templates)
    end
  end

  defp list_templates(nil, nil) do
    # List all templates for all known combinations
    for comp_type <- ComponentTemplates.available_component_types(),
        sec_mode <- ComponentTemplates.available_security_modes(),
        reduce: [] do
      acc ->
        case ComponentTemplates.list(comp_type, sec_mode) do
          {:ok, templates} -> acc ++ templates
          {:error, _} -> acc
        end
    end
  end

  defp list_templates(component_type, nil) do
    # List templates for a specific component type across all security modes
    for sec_mode <- ComponentTemplates.available_security_modes(), reduce: [] do
      acc ->
        case ComponentTemplates.list(component_type, sec_mode) do
          {:ok, templates} -> acc ++ templates
          {:error, _} -> acc
        end
    end
  end

  defp list_templates(nil, security_mode) do
    # List templates for a specific security mode across all component types
    for comp_type <- ComponentTemplates.available_component_types(), reduce: [] do
      acc ->
        case ComponentTemplates.list(comp_type, security_mode) do
          {:ok, templates} -> acc ++ templates
          {:error, _} -> acc
        end
    end
  end

  defp list_templates(component_type, security_mode) do
    case ComponentTemplates.list(component_type, security_mode) do
      {:ok, templates} -> templates
      {:error, _} -> []
    end
  end

  # Private helpers

  defp build_filters(params) do
    %{}
    |> maybe_add_filter(:status, parse_list(params["status"]))
    |> maybe_add_filter(:component_type, parse_list(params["component_type"]))
    |> maybe_add_filter(:gateway_id, params["gateway_id"])
    |> maybe_add_filter(:component_id, params["component_id"])
    |> maybe_add_filter(:parent_id, params["parent_id"])
    |> maybe_add_filter(:limit, parse_int(params["limit"]))
  end

  defp maybe_add_filter(filters, _key, nil), do: filters
  defp maybe_add_filter(filters, _key, []), do: filters
  defp maybe_add_filter(filters, _key, ""), do: filters
  defp maybe_add_filter(filters, key, value), do: Map.put(filters, key, value)

  defp parse_list(nil), do: nil
  defp parse_list(""), do: nil

  defp parse_list(str) when is_binary(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp get_user_actor(conn) do
    case conn.assigns[:current_scope] do
      %Scope{user: user} when not is_nil(user) ->
        conn.assigns[:ash_actor] || user

      _ ->
        nil
    end
  end

  # Check that user is authenticated (must have a principal, not a legacy static key)
  defp require_authenticated(conn) do
    case conn.assigns[:current_scope] do
      %Scope{user: user} when not is_nil(user) ->
        :ok

      _ ->
        {:error, :unauthorized}
    end
  end

  defp require_permission(conn, permission) do
    scope = conn.assigns[:current_scope]
    if RBAC.can?(scope, permission), do: :ok, else: {:error, :forbidden}
  end

  defp find_package(package_id) do
    case OnboardingPackage
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(id == ^package_id)
         |> Ash.read_one(actor: nil, authorize?: false) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, package} -> {:ok, package}
      {:error, error} -> {:error, error}
    end
  end

  defp package_to_json(package) do
    Map.merge(
      package_core_fields(package),
      package_lifecycle_fields(package)
    )
  end

  defp package_core_fields(package) do
    %{
      package_id: package.id,
      label: package.label,
      component_id: to_str(package.component_id),
      component_type: package.component_type || "gateway",
      parent_type: to_str(package.parent_type),
      parent_id: to_str(package.parent_id),
      gateway_id: to_str(package.gateway_id),
      partition_id: package_partition_id(package),
      site: to_str(package.site || package_partition_id(package)),
      status: package.status,
      security_mode: package.security_mode || "spire",
      downstream_spiffe_id: to_str(package.downstream_spiffe_id),
      selectors: package.selectors || [],
      checker_kind: to_str(package.checker_kind),
      checker_config_json: Jason.encode!(package.checker_config_json || %{}),
      metadata_json: Jason.encode!(package.metadata_json || %{}),
      kv_revision: package.kv_revision || 0,
      notes: to_str(package.notes)
    }
  end

  defp package_lifecycle_fields(package) do
    %{
      join_token_expires_at: format_datetime(package.join_token_expires_at),
      download_token_expires_at: format_datetime(package.download_token_expires_at),
      created_by: to_str(package.created_by),
      created_at: format_datetime(package.created_at),
      updated_at: format_datetime(package.updated_at),
      delivered_at: format_datetime(package.delivered_at),
      activated_at: format_datetime(package.activated_at),
      activated_from_ip: package.activated_from_ip,
      last_seen_spiffe_id: package.last_seen_spiffe_id,
      revoked_at: format_datetime(package.revoked_at),
      deleted_at: format_datetime(package.deleted_at),
      deleted_by: to_str(package.deleted_by),
      deleted_reason: to_str(package.deleted_reason)
    }
  end

  defp to_str(nil), do: ""
  defp to_str(val), do: val

  defp event_to_json(event) do
    %{
      event_time: format_datetime(event.event_time),
      event_type: event.event_type,
      actor: event.actor || "",
      source_ip: event.source_ip || "",
      details_json: Jason.encode!(event.details_json || %{})
    }
  end

  defp format_datetime(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end

  defp format_datetime(nil), do: nil

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_int(n) when is_integer(n), do: n
end
