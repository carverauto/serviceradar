defmodule ServiceRadarWebNGWeb.DashboardPackagePublishController do
  @moduledoc """
  CLI-facing dashboard-package publish/enable/disable HTTP API.

  Endpoints

      POST /api/v1/dashboard-packages          # multipart upload
      POST /api/v1/dashboard-packages/:id/enable
      POST /api/v1/dashboard-packages/:id/disable

  All three are gated by:

    1. The `:api_key_auth` Phoenix pipeline (Guardian JWT bearer auth).
    2. The `RequireOauthScope` plug, which rejects any bearer token whose
       `scopes` claim does not include `dashboard.publish`. The publish
       endpoint also accepts session-authenticated browsers via the
       fallback `cli.dashboard.publish` permission so the existing Settings
       LiveView upload modal continues to work without rewiring.
    3. A per-action RBAC check inside this controller
       (`cli.dashboard.{publish,enable,disable}`) — defense in depth, since
       the bearer scope is minted at login and doesn't shrink when an
       admin's role is downgraded later.

  Multipart parts are pinned to specific content types and per-part size
  caps; the slug regex and version-overwrite + slug-ownership rules live in
  `ServiceRadarWebNG.Dashboards.Packages` so the LiveView upload path can't
  diverge.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadar.Security.RateLimiter
  alias ServiceRadarWebNG.Audit.DashboardPublishEvents
  alias ServiceRadarWebNG.Dashboards.Packages
  alias ServiceRadarWebNG.Plugins.Storage
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.ClientIP

  require Logger

  @manifest_max_bytes 262_144
  @route_slug_pattern ~r/^[a-z0-9][a-z0-9-]{1,62}$/
  @allowed_renderer_types ~w(application/javascript text/javascript application/wasm)
  @allowed_manifest_types ~w(application/json text/json)

  # Per-grant rate limits live in
  # `config :serviceradar_core, ServiceRadar.Security.RateLimiter`
  # as the `:dashboard_publish` (create) and
  # `:dashboard_publish_admin` (lifecycle) buckets. This endpoint
  # is multiplexed across two action shapes with different
  # acceptable rates, so the limit check stays inline rather than
  # at a single pipeline level.

  @doc """
  POST /api/v1/dashboard-packages — publish a dashboard package version.

  Multipart parts:

    * `manifest` — required, `application/json`, ≤ 256 KB.
    * `renderer` — required, `application/javascript`/`text/javascript`/`application/wasm`,
      ≤ `Storage.max_upload_bytes/0` (50 MB default).
    * `route`    — optional text field; when present, must match
      `^[a-z0-9][a-z0-9-]{1,62}$` and SHALL be bound to the published package.
  """
  def create(conn, params) do
    with :ok <- enforce_permission(conn, "cli.dashboard.publish"),
         :ok <- enforce_publish_rate_limit(conn),
         {:ok, manifest_bytes} <- read_manifest_part(params),
         {:ok, renderer_bytes} <- read_renderer_part(params),
         {:ok, route_slug} <- normalize_route_param(params),
         opts = build_publish_opts(conn, route_slug),
         {:ok, %{} = result} <- Packages.publish(manifest_bytes, renderer_bytes, opts) do
      record_publish_audit(conn, result, :written_or_noop)
      respond_publish(conn, result)
    else
      {:error, :forbidden, permission} ->
        forbidden(conn, permission)

      {:error, :rate_limited, retry_after} ->
        rate_limited(conn, retry_after)

      {:error, {:missing_part, part}} ->
        record_rejection(conn, "missing_part", %{part: part})
        bad_request(conn, "missing_part", %{part: part})

      {:error, {:unsupported_media_type, part, ct}} ->
        record_rejection(conn, "unsupported_media_type", %{part: part, content_type: ct})
        send_error(conn, 415, "unsupported_media_type", %{part: part})

      {:error, {:payload_too_large, part}} ->
        record_rejection(conn, "payload_too_large", %{part: part})
        send_error(conn, 413, "payload_too_large", %{part: part})

      {:error, {:invalid_route, slug}} ->
        record_rejection(conn, "invalid_route", %{route: slug})

        bad_request(conn, "invalid_route", %{
          reason: "route_slug must match #{Regex.source(@route_slug_pattern)}"
        })

      {:error, {:slug_in_use, %{owner_dashboard_id: owner, route_slug: slug}}} ->
        record_rejection(conn, "slug_in_use", %{owner_dashboard_id: owner, route_slug: slug})
        send_error(conn, 409, "slug_in_use", %{route: slug, owner_dashboard_id: owner})

      {:error, {:version_already_published, info}} ->
        record_rejection(conn, "version_already_published", info)
        send_error(conn, 409, "version_already_published", info)

      {:error, :digest_mismatch} ->
        record_rejection(conn, "unprocessable_renderer", %{reason: "sha256_mismatch"})
        send_error(conn, 422, "unprocessable_renderer", %{reason: "sha256_mismatch"})

      {:error, errors} when is_list(errors) ->
        record_rejection(conn, "invalid_manifest", %{errors: errors})
        bad_request(conn, "invalid_manifest", %{errors: errors})

      {:error, reason} ->
        Logger.warning("dashboard publish failed: #{inspect(reason)}")
        record_rejection(conn, "publish_failed", %{reason: inspect(reason)})
        internal_error(conn, "publish_failed")
    end
  end

  @doc """
  POST /api/v1/dashboard-packages/:id/enable
  """
  def enable(conn, %{"id" => id} = params) do
    with :ok <- enforce_permission(conn, "cli.dashboard.enable"),
         :ok <- enforce_admin_rate_limit(conn),
         {:ok, route_slug} <- normalize_optional_route(params),
         {:ok, ash_opts} <- build_actor_opts(conn),
         {:ok, package} <- Packages.enable(id, ash_opts),
         {:ok, instance} <- maybe_bind_route(package, route_slug, ash_opts) do
      DashboardPublishEvents.record(conn, :dashboard_enable, %{
        package_id: package.id,
        dashboard_id: package.dashboard_id,
        version: package.version,
        route_slug: instance && instance.route_slug,
        content_hash: package.content_hash,
        result: :written
      })

      send_package_response(conn, package, instance, :enabled)
    else
      {:error, :forbidden, permission} ->
        forbidden(conn, permission)

      {:error, :rate_limited, retry_after} ->
        rate_limited(conn, retry_after)

      {:error, :not_found} ->
        send_error(conn, 404, "not_found", %{id: id})

      {:error, :verification_required} ->
        send_error(conn, 409, "verification_required", %{id: id})

      {:error, {:invalid_route, slug}} ->
        bad_request(conn, "invalid_route", %{
          reason: "route_slug must match #{Regex.source(@route_slug_pattern)}",
          route: slug
        })

      {:error, {:slug_in_use, %{owner_dashboard_id: owner, route_slug: slug}}} ->
        send_error(conn, 409, "slug_in_use", %{route: slug, owner_dashboard_id: owner})

      {:error, reason} ->
        Logger.warning("dashboard enable failed: #{inspect(reason)}")
        internal_error(conn, "enable_failed")
    end
  end

  @doc """
  POST /api/v1/dashboard-packages/:id/disable
  """
  def disable(conn, %{"id" => id}) do
    with :ok <- enforce_permission(conn, "cli.dashboard.disable"),
         :ok <- enforce_admin_rate_limit(conn),
         {:ok, ash_opts} <- build_actor_opts(conn),
         {:ok, package} <- Packages.disable(id, ash_opts) do
      DashboardPublishEvents.record(conn, :dashboard_disable, %{
        package_id: package.id,
        dashboard_id: package.dashboard_id,
        version: package.version,
        content_hash: package.content_hash,
        result: :written
      })

      send_package_response(conn, package, nil, :disabled)
    else
      {:error, :forbidden, permission} ->
        forbidden(conn, permission)

      {:error, :rate_limited, retry_after} ->
        rate_limited(conn, retry_after)

      {:error, :not_found} ->
        send_error(conn, 404, "not_found", %{id: id})

      {:error, reason} ->
        Logger.warning("dashboard disable failed: #{inspect(reason)}")
        internal_error(conn, "disable_failed")
    end
  end

  ## Permission + rate-limit helpers

  defp enforce_permission(conn, permission) do
    scope = conn.assigns[:current_scope]

    if scope && RBAC.can?(scope, permission) do
      :ok
    else
      {:error, :forbidden, permission}
    end
  end

  defp enforce_publish_rate_limit(conn) do
    enforce_rate_limit(conn, :dashboard_publish)
  end

  defp enforce_admin_rate_limit(conn) do
    enforce_rate_limit(conn, :dashboard_publish_admin)
  end

  defp enforce_rate_limit(conn, bucket) do
    case RateLimiter.check_and_record(bucket, rate_limit_key(conn)) do
      :ok -> :ok
      {:error, retry_after} -> {:error, :rate_limited, retry_after}
    end
  end

  # Rate-limit per JWT id when available (CLI session token), per IP otherwise
  # (session-auth LiveView upload — covered by the fallback permission path).
  defp rate_limit_key(conn) do
    case conn.assigns[:jwt_jti] do
      jti when is_binary(jti) and byte_size(jti) > 0 -> "jti:#{jti}"
      _ -> "ip:#{ClientIP.get(conn)}"
    end
  end

  ## Multipart parsing + per-part validation

  defp read_manifest_part(params) do
    read_upload_part(params, "manifest", @allowed_manifest_types, @manifest_max_bytes)
  end

  defp read_renderer_part(params) do
    read_upload_part(params, "renderer", @allowed_renderer_types, Storage.max_upload_bytes())
  end

  defp read_upload_part(params, name, allowed_types, max_bytes) do
    case Map.get(params, name) do
      nil ->
        {:error, {:missing_part, name}}

      %Plug.Upload{path: path, content_type: ct} = upload ->
        normalized_ct = normalize_content_type(ct)

        cond do
          normalized_ct not in allowed_types ->
            {:error, {:unsupported_media_type, name, normalized_ct}}

          file_too_large?(path, max_bytes) ->
            {:error, {:payload_too_large, name}}

          true ->
            case File.read(path) do
              {:ok, bytes} when byte_size(bytes) > max_bytes ->
                {:error, {:payload_too_large, name}}

              {:ok, bytes} ->
                {:ok, bytes}

              {:error, reason} ->
                Logger.warning("read_upload_part #{name} failed: #{inspect(reason)} upload=#{inspect(upload)}")
                {:error, {:missing_part, name}}
            end
        end

      _ ->
        {:error, {:missing_part, name}}
    end
  end

  defp file_too_large?(path, max_bytes) when is_binary(path) and is_integer(max_bytes) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size > max_bytes
      _ -> false
    end
  end

  defp normalize_content_type(nil), do: ""

  defp normalize_content_type(ct) when is_binary(ct) do
    ct
    |> String.split(";", parts: 2)
    |> List.first()
    |> case do
      nil -> ""
      str -> String.trim(str)
    end
  end

  defp normalize_route_param(params) do
    case Map.get(params, "route") do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      slug when is_binary(slug) -> validate_route_slug(slug)
      _ -> {:error, {:invalid_route, nil}}
    end
  end

  defp normalize_optional_route(params) do
    case Map.get(params, "route") do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      slug when is_binary(slug) -> validate_route_slug(slug)
      _ -> {:error, {:invalid_route, nil}}
    end
  end

  defp validate_route_slug(slug) do
    if Regex.match?(@route_slug_pattern, slug) do
      {:ok, slug}
    else
      {:error, {:invalid_route, slug}}
    end
  end

  ## Ash actor + opts

  defp build_publish_opts(conn, route_slug) do
    {:ok, base} = build_actor_opts(conn)

    Keyword.put(base, :route_slug, route_slug)
  end

  defp build_actor_opts(conn) do
    case conn.assigns[:current_scope] do
      nil -> {:error, :forbidden, "cli.dashboard.publish"}
      scope -> {:ok, [scope: scope]}
    end
  end

  defp maybe_bind_route(_package, nil, _opts), do: {:ok, nil}

  defp maybe_bind_route(package, slug, opts) when is_binary(slug) do
    Packages.bind_route(package, slug, Keyword.put(opts, :enabled, true))
  end

  ## Audit

  defp record_publish_audit(conn, %{package: %DashboardPackage{} = package} = result, :written_or_noop) do
    DashboardPublishEvents.record(conn, :dashboard_publish, %{
      package_id: package.id,
      dashboard_id: package.dashboard_id,
      version: package.version,
      route_slug: result_route_slug(result),
      content_hash: package.content_hash,
      result: result.result
    })
  end

  defp record_rejection(conn, reason, attrs) do
    DashboardPublishEvents.record(
      conn,
      :dashboard_publish,
      Map.merge(%{result: :rejected, reason: reason}, attrs)
    )
  end

  defp result_route_slug(%{instance: %{route_slug: slug}}), do: slug
  defp result_route_slug(_), do: nil

  ## Responses

  defp respond_publish(conn, %{package: %DashboardPackage{} = package} = result) do
    status_code = if result.result == :idempotent_noop, do: 200, else: 200

    conn
    |> put_status(status_code)
    |> put_resp_header("cache-control", "no-store")
    |> json(%{
      id: package.id,
      dashboard_id: package.dashboard_id,
      version: package.version,
      route_slug: result_route_slug(result),
      status: package.status,
      content_hash: package.content_hash,
      result: result.result
    })
  end

  defp send_package_response(conn, %DashboardPackage{} = package, instance, expected_status) do
    conn
    |> put_status(:ok)
    |> put_resp_header("cache-control", "no-store")
    |> json(%{
      id: package.id,
      dashboard_id: package.dashboard_id,
      version: package.version,
      route_slug: instance && instance.route_slug,
      status: package.status,
      content_hash: package.content_hash,
      expected_status: expected_status
    })
  end

  defp forbidden(conn, permission) do
    send_error(conn, 403, "forbidden", %{permission: permission})
  end

  defp rate_limited(conn, retry_after) do
    conn
    |> put_resp_header("retry-after", to_string(retry_after))
    |> send_error(429, "rate_limited", %{retry_after: retry_after})
  end

  defp bad_request(conn, error, details) do
    send_error(conn, 400, error, details)
  end

  defp internal_error(conn, error) do
    send_error(conn, 500, error, %{})
  end

  defp send_error(conn, status, error, details) do
    body = Map.merge(%{error: error}, details)

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
