defmodule ServiceRadarWebNG.Api.EdgeController do
  @moduledoc """
  JSON API controller for edge onboarding operations.

  Provides REST endpoints for managing edge onboarding packages, matching
  the API contract from the Go serviceradar-core implementation.
  """

  use ServiceRadarWebNGWeb, :controller

  require Ash.Query

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.Edge.OnboardingPackage
  alias ServiceRadarWebNG.Edge.OnboardingPackages
  alias ServiceRadarWebNG.Edge.OnboardingEvents
  alias ServiceRadarWebNG.Edge.ComponentTemplates
  alias ServiceRadarWebNG.Edge.BundleGenerator
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadar.Identity.Tenant

  action_fallback ServiceRadarWebNG.Api.FallbackController

  @doc """
  GET /api/admin/edge-packages/defaults

  Returns default selectors and metadata for package creation.
  """
  def defaults(conn, _params) do
    defaults = OnboardingPackages.defaults()

    json(conn, %{
      selectors: defaults.selectors,
      metadata: defaults.metadata
    })
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

    with {:ok, tenant} <- require_tenant(conn) do
      packages = OnboardingPackages.list(filters, tenant: tenant)
      json(conn, Enum.map(packages, &package_to_json/1))
    end
  end

  @doc """
  POST /api/admin/edge-packages

  Creates a new edge onboarding package.
  """
  def create(conn, params) do
    actor = get_actor(conn)
    source_ip = get_client_ip(conn)

    attrs = %{
      label: params["label"],
      component_id: params["component_id"] || params["gateway_id"],
      component_type: params["component_type"] || "gateway",
      parent_type: params["parent_type"],
      parent_id: params["parent_id"],
      gateway_id: params["gateway_id"],
      site: params["site"],
      security_mode: params["security_mode"] || "spire",
      selectors: params["selectors"] || [],
      checker_kind: params["checker_kind"],
      checker_config_json: params["checker_config_json"],
      metadata_json: params["metadata_json"],
      notes: params["notes"],
      created_by: actor,
      downstream_spiffe_id: params["downstream_spiffe_id"]
    }

    with {:ok, tenant} <- require_tenant(conn) do
      opts = [
        join_token_ttl_seconds: params["join_token_ttl_seconds"] || 86_400,
        download_token_ttl_seconds: params["download_token_ttl_seconds"] || 86_400,
        actor: actor,
        source_ip: source_ip,
        tenant: tenant
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
    with {:ok, tenant} <- require_tenant(conn) do
      case OnboardingPackages.get(id, tenant: tenant) do
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
    actor = get_actor(conn)
    source_ip = get_client_ip(conn)

    with {:ok, tenant} <- require_tenant(conn) do
      case OnboardingPackages.delete(id, actor: actor, source_ip: source_ip, tenant: tenant) do
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
  def events(conn, %{"id" => id, "limit" => limit}) do
    events_list(conn, id, String.to_integer(limit))
  end

  def events(conn, %{"id" => id}) do
    events_list(conn, id, 50)
  end

  defp events_list(conn, package_id, limit) do
    # First verify package exists
    with {:ok, tenant} <- require_tenant(conn) do
      case OnboardingPackages.get(package_id, tenant: tenant) do
        {:ok, _package} ->
          events = OnboardingEvents.list_for_package(package_id, limit: limit, tenant: tenant)
          json(conn, Enum.map(events, &event_to_json/1))

        {:error, :not_found} ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  POST /api/admin/edge-packages/:id/download

  Delivers a package to the client, returning tokens and certificates.
  Requires a valid download_token in the request body.
  """
  def download(conn, %{"id" => id} = params) do
    download_token = params["download_token"]

    if download_token in [nil, ""] do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "download_token is required"})
    else
      source_ip = get_client_ip(conn)
      actor = get_actor(conn)

      case download_with_token(id, download_token, source_ip, actor) do
        {:ok, result} ->
          json(conn, result)

        {:error, reason} ->
          handle_download_error(conn, reason)
      end
    end
  end

  defp download_with_token(id, download_token, source_ip, actor) do
    case find_package_across_tenants(id) do
      {:ok, _package, tenant_schema} ->
        deliver_package(id, download_token, tenant_schema, source_ip, actor)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp deliver_package(id, download_token, tenant_schema, source_ip, actor) do
    case OnboardingPackages.deliver(id, download_token,
           actor: actor,
           source_ip: source_ip,
           tenant: tenant_schema,
           authorize?: false
         ) do
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
       when reason in [:already_delivered, :revoked, :deleted] do
    conn |> put_status(:conflict) |> json(%{error: "package #{reason}"})
  end

  defp handle_bundle_error(conn, {:bundle_error, reason}) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{error: "Failed to generate bundle: #{inspect(reason)}"})
  end

  defp handle_bundle_error(conn, reason)
       when reason in [
              :invalid_token,
              :expired,
              :not_found,
              :already_delivered,
              :revoked,
              :deleted
            ] do
    handle_download_error(conn, reason)
  end

  defp handle_bundle_error(conn, reason) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{error: "bundle request failed: #{inspect(reason)}"})
  end

  @doc """
  GET /api/edge-packages/:id/bundle

  Downloads the package as a tarball containing certificates, config, and install script.
  Requires a valid download token as a query parameter.

  Query params:
    - token: the download token (required)

  Returns: application/gzip tarball
  """
  def bundle(conn, %{"id" => id, "token" => download_token}) when byte_size(download_token) > 0 do
    source_ip = get_client_ip(conn)

    case bundle_with_token(id, download_token, source_ip) do
      {:ok, tarball, filename} ->
        conn
        |> put_resp_content_type("application/gzip")
        |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
        |> send_resp(200, tarball)

      {:error, reason} ->
        handle_bundle_error(conn, reason)
    end
  end

  def bundle(conn, %{"id" => _id}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "token query parameter is required"})
  end

  defp bundle_with_token(id, download_token, source_ip) do
    with {:ok, _package, tenant_schema} <- find_package_across_tenants(id),
         {:ok, %{package: package, join_token: join_token, bundle_pem: bundle_pem}} <-
           deliver_package(id, download_token, tenant_schema, source_ip, nil),
         {:ok, tarball} <-
           wrap_bundle_error(
             BundleGenerator.create_tarball(package, bundle_pem || "", join_token)
           ) do
      filename = BundleGenerator.bundle_filename(package)
      {:ok, tarball, filename}
    else
      {:error, reason} -> {:error, reason}
      {:error, reason, _} -> {:error, reason}
      {:error, reason, _, _} -> {:error, reason}
    end
  end

  defp wrap_bundle_error({:ok, tarball}), do: {:ok, tarball}
  defp wrap_bundle_error({:error, reason}), do: {:error, {:bundle_error, reason}}

  @doc """
  POST /api/admin/edge-packages/:id/revoke

  Revokes a package, preventing further delivery.
  """
  def revoke(conn, %{"id" => id} = params) do
    actor = get_actor(conn)
    source_ip = get_client_ip(conn)
    reason = params["reason"]

    with {:ok, tenant} <- require_tenant(conn) do
      case OnboardingPackages.revoke(id,
             actor: actor,
             source_ip: source_ip,
             reason: reason,
             tenant: tenant
           ) do
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

    templates = list_templates(component_type, security_mode)
    json(conn, templates)
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

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  defp get_actor(conn) do
    case conn.assigns[:current_scope] do
      %{user: %{email: email}} -> email
      _ -> nil
    end
  end

  defp require_tenant(conn) do
    case conn.assigns[:current_scope] do
      %Scope{active_tenant: %Tenant{} = tenant} ->
        {:ok, tenant}

      %Scope{} = scope ->
        scope
        |> Scope.tenant_id()
        |> load_tenant()

      _ ->
        {:error, :unauthorized}
    end
  end

  defp load_tenant(nil), do: {:error, :unauthorized}

  defp load_tenant(tenant_id) do
    case Ash.get(Tenant, tenant_id, authorize?: false) do
      {:ok, %Tenant{} = tenant} -> {:ok, tenant}
      _ -> {:error, :unauthorized}
    end
  end

  defp get_client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded
        |> String.split(",")
        |> List.first()
        |> String.trim()

      [] ->
        conn.remote_ip
        |> :inet.ntoa()
        |> to_string()
    end
  end

  defp find_package_across_tenants(package_id) do
    TenantSchemas.list_schemas()
    |> Enum.reduce_while({:error, :not_found}, fn schema, _ ->
      case OnboardingPackage
           |> Ash.Query.for_read(:read)
           |> Ash.Query.filter(id == ^package_id)
           |> Ash.read_one(tenant: schema, authorize?: false) do
        {:ok, nil} ->
          {:cont, {:error, :not_found}}

        {:ok, package} ->
          {:halt, {:ok, package, schema}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
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
      site: to_str(package.site),
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

  defp format_datetime(nil), do: nil

  defp format_datetime(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end
end
