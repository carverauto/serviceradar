defmodule ServiceRadarWebNG.Api.CollectorEnrollController do
  @moduledoc """
  Legacy API controller for collector enrollment.

  This endpoint is retained for backward compatibility. New collector enrollment
  downloads the bundle from `/api/collectors/:id/bundle` using the same token.

  The enrollment flow:
  1. Collector decodes the self-contained token to get API URL and secret
  2. Legacy clients call `GET /api/enroll/collector/:package_id?token=<secret>`
  3. API validates the token and returns enrollment data
  4. CLI writes files to `/etc/serviceradar/` and restarts the service

  Legacy route: `/api/enroll/:package_id` (kept for backward compatibility).
  """

  use ServiceRadarWebNGWeb, :controller

  require Ash.Query
  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.CollectorPackage
  alias ServiceRadarWebNG.Edge.EnrollmentToken
  alias ServiceRadarWebNGWeb.ClientIP

  @doc """
  GET /api/enroll/collector/:package_id

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
    # In a single deployment, DB connection's search_path determines the schema
    case find_package(package_id) do
      {:ok, package} ->
        do_enrollment(package, token_secret, source_ip)

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

  defp do_enrollment(package, token_secret, source_ip) do
    with :ok <- validate_package_ready(package),
         :ok <- validate_token(package, token_secret),
         :ok <- validate_not_already_enrolled(package),
         {:ok, creds_content} <- get_nats_creds(package),
         {:ok, _updated} <- mark_enrolled(package, source_ip) do
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

  defp mark_enrolled(package, source_ip) do
    # In a single deployment, DB connection's search_path determines the schema
    actor = SystemActor.system(:enroll_controller)

    package
    |> Ash.Changeset.for_update(:download)
    |> Ash.Changeset.set_argument(:source_ip, source_ip)
    |> Ash.update(actor: actor)
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
    nats_url = Application.get_env(:serviceradar_web_ng, :nats_url, "nats://nats:4222")

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

    # Return as JSON (most YAML parsers accept JSON)
    Jason.encode!(config)
  end

  defp find_package(package_id) do
    # In a single deployment, DB connection's search_path determines the schema
    actor = SystemActor.system(:enroll_controller)

    case CollectorPackage
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(id == ^package_id)
         |> Ash.read_one(actor: actor) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, package} -> {:ok, package}
      {:error, error} -> {:error, error}
    end
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

  defp add_collector_defaults(config, :sflow) do
    Map.put(config, "sflow", %{
      "listen" => "0.0.0.0:6343",
      "protocols" => ["sflow-v5"]
    })
  end

  defp add_collector_defaults(config, :otel) do
    Map.put(config, "otel", %{
      "grpc_listen" => "0.0.0.0:4317",
      "http_listen" => "0.0.0.0:4318"
    })
  end

  defp add_collector_defaults(config, :falcosidekick) do
    Map.put(config, "falcosidekick", %{
      "nats_subject" => "events.falco.raw",
      "nats_credsfile" => "/etc/serviceradar/creds/nats.creds",
      "nats_cacertfile" => "/etc/serviceradar/certs/root.pem"
    })
  end

  defp add_collector_defaults(config, _), do: config

  defp deep_merge(left, right) do
    Map.merge(left, right, fn
      _key, %{} = l, %{} = r -> deep_merge(l, r)
      _key, _l, r -> r
    end)
  end

  defp get_client_ip(conn) do
    ClientIP.get(conn)
  end
end
