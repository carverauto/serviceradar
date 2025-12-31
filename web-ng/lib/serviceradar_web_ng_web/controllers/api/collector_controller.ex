defmodule ServiceRadarWebNG.Api.CollectorController do
  @moduledoc """
  JSON API controller for collector package operations.

  Provides REST endpoints for managing collector packages (flowgger, trapd, netflow, otel),
  including creation, listing, download, and revocation.
  """

  use ServiceRadarWebNGWeb, :controller

  require Ash.Query

  alias ServiceRadar.Edge.CollectorPackage
  alias ServiceRadar.Edge.NatsCredential

  action_fallback ServiceRadarWebNG.Api.FallbackController

  @doc """
  GET /api/admin/collectors

  Lists collector packages for the current tenant.
  """
  def index(conn, params) do
    tenant_id = get_tenant_id(conn)
    limit = parse_int(params["limit"]) || 50

    query =
      CollectorPackage
      |> Ash.Query.for_read(:list)
      |> Ash.Query.limit(limit)

    query =
      if status = params["status"] do
        status_atom = String.to_existing_atom(status)
        Ash.Query.filter(query, status == ^status_atom)
      else
        query
      end

    query =
      if collector_type = params["collector_type"] do
        type_atom = String.to_existing_atom(collector_type)
        Ash.Query.filter(query, collector_type == ^type_atom)
      else
        query
      end

    packages = Ash.read!(query, tenant: tenant_id, authorize?: false)

    json(conn, Enum.map(packages, &package_to_json/1))
  end

  @doc """
  POST /api/admin/collectors

  Creates a new collector package.

  Request body:
    - collector_type: flowgger, trapd, netflow, or otel (required)
    - site: deployment site/location (optional)
    - hostname: target hostname (optional)
    - config_overrides: collector-specific config overrides (optional)
  """
  def create(conn, params) do
    tenant_id = get_tenant_id(conn)
    _actor = get_actor(conn)

    collector_type = params["collector_type"]

    unless collector_type in ["flowgger", "trapd", "netflow", "otel"] do
      return_error(conn, :bad_request, "collector_type must be one of: flowgger, trapd, netflow, otel")
    else
      attrs = %{
        collector_type: String.to_existing_atom(collector_type),
        site: params["site"],
        hostname: params["hostname"],
        config_overrides: params["config_overrides"] || %{}
      }

      case CollectorPackage
           |> Ash.Changeset.for_create(:create, attrs)
           |> Ash.Changeset.force_change_attribute(:tenant_id, tenant_id)
           |> Ash.create(authorize?: false) do
        {:ok, package} ->
          conn
          |> put_status(:created)
          |> json(package_to_json(package))

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  GET /api/admin/collectors/:id

  Gets a single collector package by ID.
  """
  def show(conn, %{"id" => id}) do
    tenant_id = get_tenant_id(conn)

    case CollectorPackage
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(id == ^id)
         |> Ash.read_one(tenant: tenant_id, authorize?: false) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, package} -> json(conn, package_to_json(package))
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  GET /api/admin/collectors/:id/download

  Downloads the collector package with NATS credentials.
  Requires a valid download token.
  """
  def download(conn, %{"id" => id} = params) do
    tenant_id = get_tenant_id(conn)
    download_token = params["download_token"]
    source_ip = get_client_ip(conn)

    if is_nil(download_token) or download_token == "" do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "download_token is required"})
    else
      case do_download(id, download_token, tenant_id, source_ip) do
        {:ok, result} ->
          json(conn, result)

        {:error, :not_found} ->
          {:error, :not_found}

        {:error, :not_ready} ->
          conn
          |> put_status(:conflict)
          |> json(%{error: "package is not ready for download"})

        {:error, :invalid_token} ->
          conn
          |> put_status(:unauthorized)
          |> json(%{error: "invalid download token"})

        {:error, :token_expired} ->
          conn
          |> put_status(:gone)
          |> json(%{error: "download token expired"})

        {:error, reason} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{error: "download failed: #{inspect(reason)}"})
      end
    end
  end

  @doc """
  POST /api/admin/collectors/:id/revoke

  Revokes a collector package and its associated NATS credentials.
  """
  def revoke(conn, %{"id" => id} = params) do
    tenant_id = get_tenant_id(conn)
    reason = params["reason"]

    case CollectorPackage
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(id == ^id)
         |> Ash.read_one(tenant: tenant_id, authorize?: false) do
      {:ok, nil} ->
        {:error, :not_found}

      {:ok, package} ->
        case package
             |> Ash.Changeset.for_update(:revoke)
             |> Ash.Changeset.set_argument(:reason, reason)
             |> Ash.update(authorize?: false) do
          {:ok, updated_package} ->
            json(conn, package_to_json(updated_package))

          {:error, changeset} ->
            {:error, changeset}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  GET /api/admin/nats/credentials

  Lists NATS credentials issued to the current tenant.
  """
  def credentials(conn, params) do
    tenant_id = get_tenant_id(conn)
    limit = parse_int(params["limit"]) || 50

    query =
      NatsCredential
      |> Ash.Query.for_read(:read)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(limit)

    query =
      if status = params["status"] do
        status_atom = String.to_existing_atom(status)
        Ash.Query.filter(query, status == ^status_atom)
      else
        query
      end

    query =
      if collector_type = params["collector_type"] do
        type_atom = String.to_existing_atom(collector_type)
        Ash.Query.filter(query, collector_type == ^type_atom)
      else
        query
      end

    credentials = Ash.read!(query, tenant: tenant_id, authorize?: false)

    json(conn, Enum.map(credentials, &credential_to_json/1))
  end

  @doc """
  GET /api/admin/nats/account

  Gets the current tenant's NATS account status.
  """
  def account_status(conn, _params) do
    tenant_id = get_tenant_id(conn)

    case ServiceRadar.Identity.Tenant
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(id == ^tenant_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        {:error, :not_found}

      {:ok, tenant} ->
        json(conn, %{
          tenant_id: tenant.id,
          slug: tenant.slug,
          nats_account_status: to_string(tenant.nats_account_status),
          nats_account_public_key: tenant.nats_account_public_key,
          nats_account_provisioned_at: format_datetime(tenant.nats_account_provisioned_at)
        })

      {:error, error} ->
        {:error, error}
    end
  end

  # Private helpers

  defp do_download(package_id, download_token, tenant_id, source_ip) do
    with {:ok, package} <- get_package(package_id, tenant_id),
         :ok <- validate_package_ready(package),
         :ok <- validate_download_token(package, download_token),
         {:ok, creds_content} <- get_nats_creds(package),
         {:ok, updated_package} <- mark_downloaded(package, source_ip) do
      {:ok,
       %{
         package: package_to_json(updated_package),
         nats_creds_file: creds_content,
         collector_config: generate_collector_config(updated_package),
         install_script: generate_install_script(updated_package)
       }}
    end
  end

  defp get_package(package_id, tenant_id) do
    case CollectorPackage
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(id == ^package_id)
         |> Ash.read_one(tenant: tenant_id, authorize?: false) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, package} -> {:ok, package}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_package_ready(package) do
    if package.status == :ready do
      :ok
    else
      {:error, :not_ready}
    end
  end

  defp validate_download_token(package, token) do
    cond do
      is_nil(package.download_token_hash) ->
        {:error, :invalid_token}

      DateTime.compare(DateTime.utc_now(), package.download_token_expires_at) == :gt ->
        {:error, :token_expired}

      not verify_token_hash(token, package.download_token_hash) ->
        {:error, :invalid_token}

      true ->
        :ok
    end
  end

  defp verify_token_hash(token, hash) do
    computed_hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
    Plug.Crypto.secure_compare(computed_hash, hash)
  end

  defp get_nats_creds(_package) do
    # TODO: Retrieve NATS credentials content from secure storage
    # For now, return a placeholder
    {:ok, "# NATS credentials file\n# Generated by ServiceRadar\n"}
  end

  defp mark_downloaded(package, source_ip) do
    package
    |> Ash.Changeset.for_update(:download)
    |> Ash.Changeset.set_argument(:source_ip, source_ip)
    |> Ash.update(authorize?: false)
  end

  defp generate_collector_config(package) do
    # Generate collector-specific configuration
    config = %{
      collector_type: to_string(package.collector_type),
      site: package.site,
      hostname: package.hostname
    }

    config = Map.merge(config, package.config_overrides || %{})
    Jason.encode!(config)
  end

  defp generate_install_script(package) do
    """
    #!/bin/bash
    # ServiceRadar #{package.collector_type} Collector Installation Script
    # Generated by ServiceRadar Platform

    set -e

    COLLECTOR_TYPE="#{package.collector_type}"
    SITE="#{package.site || "default"}"
    HOSTNAME="#{package.hostname || "$(hostname)"}"

    echo "Installing ServiceRadar $COLLECTOR_TYPE collector..."

    # Place NATS credentials
    mkdir -p /etc/serviceradar/creds
    # NATS creds should be placed in /etc/serviceradar/creds/nats.creds

    echo "Installation complete. Start the collector with:"
    echo "  systemctl start serviceradar-$COLLECTOR_TYPE"
    """
  end

  defp package_to_json(package) do
    %{
      id: package.id,
      collector_type: to_string(package.collector_type),
      user_name: package.user_name,
      site: package.site,
      hostname: package.hostname,
      status: to_string(package.status),
      nats_credential_id: package.nats_credential_id,
      downloaded_at: format_datetime(package.downloaded_at),
      installed_at: format_datetime(package.installed_at),
      revoked_at: format_datetime(package.revoked_at),
      revoke_reason: package.revoke_reason,
      error_message: package.error_message,
      inserted_at: format_datetime(package.inserted_at),
      updated_at: format_datetime(package.updated_at)
    }
  end

  defp credential_to_json(credential) do
    %{
      id: credential.id,
      user_name: credential.user_name,
      user_public_key: credential.user_public_key,
      credential_type: to_string(credential.credential_type),
      collector_type: if(credential.collector_type, do: to_string(credential.collector_type)),
      status: to_string(credential.status),
      issued_at: format_datetime(credential.issued_at),
      expires_at: format_datetime(credential.expires_at),
      revoked_at: format_datetime(credential.revoked_at),
      revoke_reason: credential.revoke_reason
    }
  end

  defp return_error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
  end

  defp get_tenant_id(conn) do
    case conn.assigns[:current_scope] do
      %{user: %{tenant_id: tenant_id}} -> tenant_id
      _ -> nil
    end
  end

  defp get_actor(conn) do
    case conn.assigns[:current_scope] do
      %{user: %{email: email}} -> email
      _ -> nil
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

  defp format_datetime(nil), do: nil

  defp format_datetime(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end
end
