defmodule ServiceRadarWebNG.Api.EnrollController do
  @moduledoc """
  Public API controller for collector enrollment.

  This endpoint is called by `serviceradar-cli enroll --token <token>` to retrieve
  the collector's NATS credentials and configuration.

  The enrollment flow:
  1. CLI decodes the self-contained token to get API URL and secret
  2. CLI calls `GET /api/enroll/:package_id?token=<secret>`
  3. API validates the token and returns enrollment data
  4. CLI writes files to `/etc/serviceradar/` and restarts the service
  """

  use ServiceRadarWebNGWeb, :controller

  require Ash.Query
  require Logger

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.Edge.CollectorPackage
  alias ServiceRadarWebNG.Edge.EnrollmentToken

  @doc """
  GET /api/enroll/:package_id

  Enrolls a collector by returning its NATS credentials and configuration.

  Query params:
  - token: The secret portion of the enrollment token

  Returns JSON:
  ```json
  {
    "collector_type": "flowgger",
    "nats_creds": "-----BEGIN NATS USER JWT-----...",
    "config": "collector_id: abc123...",
    "install_hints": {
      "creds_path": "/etc/serviceradar/creds/nats.creds",
      "config_path": "/etc/serviceradar/config/config.yaml"
    }
  }
  ```
  """
  def enroll(conn, %{"package_id" => package_id} = params) do
    token_secret = params["token"]
    source_ip = get_client_ip(conn)

    if token_secret in [nil, ""] do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "token query parameter is required"})
    else
      case enroll_with_token(package_id, token_secret, source_ip) do
        {:ok, result} ->
          json(conn, result)

        {:error, reason} ->
          handle_enroll_error(conn, package_id, reason)
      end
    end
  end

  # Private helpers

  defp enroll_with_token(package_id, token_secret, source_ip) do
    case find_package_across_tenants(package_id) do
      {:ok, package, tenant_schema} ->
        do_enrollment(package, token_secret, source_ip, tenant_schema)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_enroll_error(conn, _package_id, :not_ready) do
    conn
    |> put_status(:conflict)
    |> json(%{error: "package is not ready for enrollment, please wait for provisioning"})
  end

  defp handle_enroll_error(conn, _package_id, :invalid_token) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "invalid enrollment token"})
  end

  defp handle_enroll_error(conn, _package_id, :token_expired) do
    conn
    |> put_status(:gone)
    |> json(%{error: "enrollment token has expired, please generate a new package"})
  end

  defp handle_enroll_error(conn, _package_id, :already_enrolled) do
    conn
    |> put_status(:conflict)
    |> json(%{error: "this package has already been enrolled"})
  end

  defp handle_enroll_error(conn, _package_id, :nats_creds_not_found) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{error: "NATS credentials not provisioned yet"})
  end

  defp handle_enroll_error(conn, _package_id, :not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "package not found"})
  end

  defp handle_enroll_error(conn, package_id, reason) do
    Logger.error("Enrollment failed for package #{package_id}: #{inspect(reason)}")

    conn
    |> put_status(:internal_server_error)
    |> json(%{error: "enrollment failed"})
  end

  defp do_enrollment(package, token_secret, source_ip, tenant_schema) do
    with :ok <- validate_package_ready(package),
         :ok <- validate_token(package, token_secret),
         :ok <- validate_not_already_enrolled(package),
         {:ok, creds_content} <- get_nats_creds(package),
         {:ok, _updated} <- mark_enrolled(package, source_ip, tenant_schema) do
      {:ok, build_enrollment_response(package, creds_content)}
    end
  end

  defp validate_package_ready(package) do
    if package.status == :ready do
      :ok
    else
      {:error, :not_ready}
    end
  end

  defp validate_token(package, token_secret) do
    cond do
      is_nil(package.download_token_hash) ->
        {:error, :invalid_token}

      not is_nil(package.download_token_expires_at) and
          DateTime.compare(DateTime.utc_now(), package.download_token_expires_at) == :gt ->
        {:error, :token_expired}

      not EnrollmentToken.verify_secret(token_secret, package.download_token_hash) ->
        {:error, :invalid_token}

      true ->
        :ok
    end
  end

  defp validate_not_already_enrolled(package) do
    # Allow re-enrollment if not fully installed yet
    if package.status in [:installed] do
      {:error, :already_enrolled}
    else
      :ok
    end
  end

  defp get_nats_creds(package) do
    case package.nats_creds_ciphertext do
      nil ->
        {:error, :nats_creds_not_found}

      encrypted_creds when is_binary(encrypted_creds) ->
        case ServiceRadar.Vault.decrypt(encrypted_creds) do
          {:ok, creds} when is_binary(creds) and creds != "" ->
            {:ok, creds}

          _ ->
            {:error, :nats_creds_not_found}
        end

      _ ->
        {:error, :nats_creds_not_found}
    end
  end

  defp mark_enrolled(package, source_ip, tenant_schema) do
    package
    |> Ash.Changeset.for_update(:download)
    |> Ash.Changeset.set_argument(:source_ip, source_ip)
    |> Ash.update(authorize?: false, tenant: tenant_schema)
  end

  defp build_enrollment_response(package, nats_creds) do
    %{
      collector_type: to_string(package.collector_type),
      package_id: package.id,
      site: package.site,
      hostname: package.hostname,
      nats_creds: nats_creds,
      config: generate_config(package),
      install_hints: %{
        creds_path: "/etc/serviceradar/creds/nats.creds",
        config_path: "/etc/serviceradar/config/config.yaml",
        service_name: "serviceradar-#{package.collector_type}"
      }
    }
  end

  defp generate_config(package) do
    nats_url =
      Application.get_env(:serviceradar_web_ng, :nats_url, "nats://nats.serviceradar.cloud:4222")

    config = %{
      "collector_id" => package.id,
      "collector_type" => to_string(package.collector_type),
      "site" => package.site || "default",
      "hostname" => package.hostname,
      "nats" => %{
        "url" => nats_url,
        "creds_file" => "/etc/serviceradar/creds/nats.creds"
      }
    }

    # Add collector-specific defaults
    config = add_collector_defaults(config, package.collector_type)

    # Merge any overrides
    config =
      if package.config_overrides && map_size(package.config_overrides) > 0 do
        deep_merge(config, package.config_overrides)
      else
        config
      end

    # Return as YAML
    encode_yaml(config)
  end

  defp find_package_across_tenants(package_id) do
    TenantSchemas.list_schemas()
    |> Enum.reduce_while({:error, :not_found}, fn schema, _ ->
      case CollectorPackage
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

  defp add_collector_defaults(config, :flowgger) do
    Map.put(config, "flowgger", %{
      "listen" => "0.0.0.0:514",
      "protocol" => "syslog",
      "format" => "rfc5424"
    })
  end

  defp add_collector_defaults(config, :trapd) do
    Map.put(config, "trapd", %{
      "listen" => "0.0.0.0:162",
      "community" => "public"
    })
  end

  defp add_collector_defaults(config, :netflow) do
    Map.put(config, "netflow", %{
      "listen" => "0.0.0.0:2055",
      "protocols" => ["netflow-v5", "netflow-v9", "ipfix"]
    })
  end

  defp add_collector_defaults(config, :otel) do
    Map.put(config, "otel", %{
      "grpc_listen" => "0.0.0.0:4317",
      "http_listen" => "0.0.0.0:4318"
    })
  end

  defp add_collector_defaults(config, _), do: config

  defp encode_yaml(map) do
    do_encode_yaml(map, 0)
  end

  defp do_encode_yaml(map, indent) when is_map(map) do
    prefix = String.duplicate("  ", indent)

    Enum.map_join(map, "\n", fn {key, value} ->
      "#{prefix}#{key}: #{encode_yaml_value(value, indent)}"
    end)
  end

  defp encode_yaml_value(value, _) when is_binary(value), do: "\"#{value}\""
  defp encode_yaml_value(value, _) when is_number(value), do: to_string(value)
  defp encode_yaml_value(value, _) when is_boolean(value), do: to_string(value)
  defp encode_yaml_value(nil, _), do: "null"

  defp encode_yaml_value(value, indent) when is_map(value) do
    if map_size(value) == 0, do: "{}", else: "\n" <> do_encode_yaml(value, indent + 1)
  end

  defp encode_yaml_value(value, _) when is_list(value) do
    if value == [], do: "[]", else: "[" <> Enum.map_join(value, ", ", &inspect/1) <> "]"
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn
      _key, %{} = l, %{} = r -> deep_merge(l, r)
      _key, _l, r -> r
    end)
  end

  defp get_client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded |> String.split(",") |> List.first() |> String.trim()

      [] ->
        conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
