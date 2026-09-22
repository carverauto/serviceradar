defmodule ServiceRadarWebNGWeb.CliAuthController do
  @moduledoc """
  RFC 8628 device-code endpoints for `@carverauto/serviceradar-cli`.

  ## Endpoints

      POST /api/v1/cli/auth/device   # mint a device authorization
      POST /api/v1/cli/auth/token    # poll for the issued JWT

  The flow is:

  1. CLI POSTs `/device` with `client_id=serviceradar-cli` and a scope.
     We mint a `DeviceAuthorization` row, return a `device_code` /
     `user_code` pair, and tell the CLI which URL to send the user to.
  2. The user opens the verification URL in a browser. The
     `/cli/auth/device` LiveView (`ServiceRadarWebNGWeb.CliDeviceAuthorizeLive`)
     handles approval; on Approve it flips the row to `:approved` and
     stamps the user's id.
  3. CLI polls `/token` with the device code. Until the row is approved,
     we return RFC 8628 §3.5 errors (`authorization_pending`,
     `slow_down`, `expired_token`, `access_denied`). On approval, we mint
     a Guardian JWT (`typ: "api"`, default 30-day TTL), persist the
     `cli_sessions` metadata row keyed on the JWT's jti, and return the
     token in the OAuth shape the CLI already parses.

  Tokens validate through the existing `ApiAuth` plug — same code path
  as the existing OAuth `password` and `client_credentials` grants.

  RBAC (proposal §12) lands in a follow-up commit; for the MVP we
  default `cli_auth_enabled = true`, `cli_session_ttl_days = 30`, and
  `cli_allowed_scopes = ["dashboard.publish"]`.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadar.Identity.CliSession
  alias ServiceRadar.Identity.DeviceAuthorization
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Security.RateLimiter
  alias ServiceRadarWebNG.Auth.Guardian

  require Logger

  @device_ttl_seconds 900
  @poll_interval 5
  @valid_clients ["serviceradar-cli"]

  # Fallback scopes used when AuthorizationSettings can't be read
  # (database unreachable during early request handling, etc). Matches
  # the migration default so the failure mode mirrors a freshly-installed
  # instance.
  @fallback_allowed_scopes ["dashboard.publish", "plugin.publish", "plugins.manage"]
  @fallback_session_ttl_days 30

  # Per-device-row token-poll rate limit: drives the OAuth `slow_down`
  # response per RFC 8628 §3.5, so it stays inline rather than living
  # at the pipeline (which can't issue the protocol-specific
  # side-effect). The per-IP rate limit on the device endpoint is
  # handled by the `:rate_limit_cli_device_auth` router pipeline.
  @token_rate_limit 60
  @token_rate_window 60

  # User-code alphabet excludes vowels and easily-confused characters
  # (0/O, 1/I) so a typed code stays unambiguous.
  @user_code_alphabet ~c"BCDFGHJKLMNPQRSTVWXZ"
  @user_code_collision_retries 5

  @doc """
  POST /api/v1/cli/auth/device — mint a device authorization.
  """
  def device(conn, params) do
    # Per-IP rate limiting happens at the
    # `:rate_limit_cli_device_auth` pipeline (router.ex). By the
    # time we reach this controller the request is under the
    # bucket's window.
    settings = load_settings()

    with :ok <- enforce_cli_auth_enabled(settings),
         {:ok, client_id} <- validate_client(params["client_id"]),
         {:ok, scope} <- validate_scope(params["scope"], settings) do
      mint_device_authorization(conn, client_id, scope)
    else
      {:error, :cli_auth_disabled} ->
        error_response(conn, 503, "cli_auth_disabled", "CLI authentication is disabled on this instance")

      {:error, :invalid_client} ->
        error_response(conn, 400, "invalid_client", "Unsupported client_id")

      {:error, :invalid_scope} ->
        error_response(conn, 400, "invalid_scope", "Requested scope is not allowed")
    end
  end

  @doc """
  POST /api/v1/cli/auth/token — poll for the issued JWT.

  Only `grant_type=urn:ietf:params:oauth:grant-type:device_code` is
  supported. The PKCE branch (`grant_type=authorization_code`) is a
  follow-up; the CLI's `--web` flow falls back to manual-token paste on
  the resulting 400 until then.
  """
  def token(conn, %{"grant_type" => "urn:ietf:params:oauth:grant-type:device_code"} = params) do
    settings = load_settings()

    case enforce_cli_auth_enabled(settings) do
      {:error, :cli_auth_disabled} ->
        error_response(
          conn,
          503,
          "cli_auth_disabled",
          "CLI authentication is disabled on this instance"
        )

      :ok ->
        case Map.get(params, "device_code") do
          device_code when is_binary(device_code) and device_code != "" ->
            handle_token_poll(conn, device_code, settings)

          _ ->
            error_response(conn, 400, "invalid_request", "Missing device_code")
        end
    end
  end

  def token(conn, %{"grant_type" => grant_type}) do
    error_response(
      conn,
      400,
      "unsupported_grant_type",
      "Grant type '#{grant_type}' is not supported"
    )
  end

  def token(conn, _params) do
    error_response(conn, 400, "invalid_request", "Missing grant_type parameter")
  end

  ## Device-mint helpers

  defp mint_device_authorization(conn, client_id, scope) do
    actor = SystemActor.system(:cli_auth)
    expires_at = DateTime.add(DateTime.utc_now(), @device_ttl_seconds, :second)

    case mint_with_user_code_retry(actor, client_id, scope, expires_at, @user_code_collision_retries) do
      {:ok, device_code, user_code} ->
        verification_uri = build_verification_uri(conn)
        verification_uri_complete = "#{verification_uri}?user_code=#{user_code}"

        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("pragma", "no-cache")
        |> send_resp(
          200,
          Jason.encode!(%{
            device_code: device_code,
            user_code: user_code,
            verification_uri: verification_uri,
            verification_uri_complete: verification_uri_complete,
            expires_in: @device_ttl_seconds,
            interval: @poll_interval
          })
        )

      {:error, :user_code_exhausted} ->
        Logger.error("CLI device authorization mint failed: user_code collision exhausted")
        error_response(conn, 500, "server_error", "Failed to allocate device authorization")

      {:error, reason} ->
        Logger.error("CLI device authorization mint failed: #{inspect(reason)}")
        error_response(conn, 500, "server_error", "Failed to create device authorization")
    end
  end

  defp mint_with_user_code_retry(_actor, _client_id, _scope, _expires_at, 0), do: {:error, :user_code_exhausted}

  defp mint_with_user_code_retry(actor, client_id, scope, expires_at, retries_left) do
    {device_code, device_code_hash} = generate_device_code()
    user_code = generate_user_code()

    attrs = %{
      device_code_hash: device_code_hash,
      user_code: user_code,
      client_id: client_id,
      scope: scope,
      expires_at: expires_at,
      interval_seconds: @poll_interval
    }

    case DeviceAuthorization.create(attrs, actor: actor) do
      {:ok, _row} ->
        {:ok, device_code, user_code}

      {:error, %Ash.Error.Invalid{errors: errors}} ->
        if Enum.any?(errors, &collision_error?/1) do
          mint_with_user_code_retry(actor, client_id, scope, expires_at, retries_left - 1)
        else
          {:error, errors}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collision_error?(%{class: :invalid, fields: fields}) when is_list(fields) do
    Enum.any?(fields, &(&1 in [:user_code, :device_code_hash]))
  end

  defp collision_error?(_), do: false

  ## Token-poll helpers

  defp handle_token_poll(conn, device_code, settings) do
    actor = SystemActor.system(:cli_auth)
    device_code_hash = sha256_hex(device_code)

    case DeviceAuthorization.get_by_device_code_hash(device_code_hash, actor: actor) do
      {:ok, nil} ->
        error_response(conn, 400, "invalid_grant", "Unknown device_code")

      {:error, _} ->
        error_response(conn, 400, "invalid_grant", "Unknown device_code")

      {:ok, row} ->
        enforce_token_rate_limit(conn, row, settings, actor)
    end
  end

  defp enforce_token_rate_limit(conn, row, settings, actor) do
    case RateLimiter.check_and_record(
           :cli_token_poll,
           row.id,
           limit: @token_rate_limit,
           window_seconds: @token_rate_window
         ) do
      :ok ->
        DeviceAuthorization.record_poll(row, actor: actor)
        dispatch_poll_state(conn, row, settings, actor)

      {:error, _retry_after} ->
        # Polling too fast — bump the row's interval and tell the CLI to
        # back off. Per RFC 8628 §3.5, slow_down is a recoverable error.
        DeviceAuthorization.slow_down(row, actor: actor)
        error_response(conn, 400, "slow_down", "Polling too fast; back off")
    end
  end

  defp dispatch_poll_state(conn, row, settings, actor) do
    cond do
      DateTime.before?(row.expires_at, DateTime.utc_now()) ->
        DeviceAuthorization.expire(row, actor: actor)
        error_response(conn, 400, "expired_token", "Device code expired")

      row.status == :pending ->
        error_response(conn, 400, "authorization_pending", "User has not yet authorized")

      row.status == :denied ->
        error_response(conn, 400, "access_denied", "User denied the request")

      row.status == :expired ->
        error_response(conn, 400, "expired_token", "Device code expired")

      row.status == :approved ->
        issue_token(conn, row, settings, actor)

      true ->
        error_response(conn, 400, "invalid_grant", "Device authorization in unexpected state")
    end
  end

  defp issue_token(conn, row, settings, actor) do
    ttl_days = settings[:cli_session_ttl_days] || @fallback_session_ttl_days

    with {:ok, user} <- load_user(row.user_id, actor),
         scopes = parse_scopes(row.scope),
         scopes_atoms = Enum.map(scopes, &scope_to_atom/1),
         {:ok, jwt, claims} <-
           Guardian.create_api_token(user,
             scopes: scopes_atoms,
             ttl: {ttl_days, :day}
           ),
         {:ok, _session} <- persist_cli_session(row, user, claims, actor) do
      expires_in =
        case claims["exp"] do
          exp when is_integer(exp) ->
            max(0, exp - System.system_time(:second))

          _ ->
            ttl_days * 24 * 60 * 60
        end

      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("pragma", "no-cache")
      |> send_resp(
        200,
        Jason.encode!(%{
          access_token: jwt,
          token_type: "Bearer",
          expires_in: expires_in,
          scope: row.scope,
          user: %{id: user.id, email: user.email}
        })
      )
    else
      {:error, :user_not_found} ->
        Logger.error("CLI token issue failed: approving user #{row.user_id} not found")
        error_response(conn, 400, "invalid_grant", "Approving user no longer exists")

      {:error, reason} ->
        Logger.error("CLI token issue failed: #{inspect(reason)}")
        error_response(conn, 500, "server_error", "Failed to issue token")
    end
  end

  defp load_user(nil, _actor), do: {:error, :user_not_found}

  defp load_user(user_id, actor) do
    case User.get_by_id(user_id, actor: actor) do
      {:ok, nil} -> {:error, :user_not_found}
      {:ok, user} -> {:ok, user}
      {:error, _} = error -> error
    end
  end

  defp persist_cli_session(row, user, claims, actor) do
    issued_at = unix_to_dt(claims["iat"]) || DateTime.utc_now()

    expires_at =
      unix_to_dt(claims["exp"]) ||
        DateTime.add(DateTime.utc_now(), @fallback_session_ttl_days * 24 * 60 * 60, :second)

    attrs = %{
      jti: claims["jti"],
      device_authorization_id: row.id,
      user_id: user.id,
      client_id: row.client_id,
      scope: row.scope,
      issued_at: issued_at,
      expires_at: expires_at
    }

    CliSession.create(attrs, actor: actor)
  end

  ## Validation helpers

  defp validate_client(client_id) when client_id in @valid_clients, do: {:ok, client_id}
  defp validate_client(_), do: {:error, :invalid_client}

  defp validate_scope(nil, settings), do: {:ok, default_scope(settings)}
  defp validate_scope("", settings), do: {:ok, default_scope(settings)}

  defp validate_scope(scope, settings) when is_binary(scope) do
    requested = parse_scopes(scope)
    allowed = settings[:cli_allowed_scopes] || @fallback_allowed_scopes

    if Enum.all?(requested, &(&1 in allowed)) do
      {:ok, scope}
    else
      {:error, :invalid_scope}
    end
  end

  defp validate_scope(_, _), do: {:error, :invalid_scope}

  defp default_scope(settings) do
    case settings[:cli_allowed_scopes] || @fallback_allowed_scopes do
      [first | _] -> first
      _ -> "dashboard.publish"
    end
  end

  ## Settings cache

  defp load_settings do
    actor = SystemActor.system(:cli_auth)

    case AuthorizationSettings.get_settings(actor: actor) do
      {:ok, %{} = record} ->
        %{
          cli_auth_enabled: record.cli_auth_enabled,
          cli_session_ttl_days: record.cli_session_ttl_days,
          cli_allowed_scopes: record.cli_allowed_scopes
        }

      _ ->
        %{
          cli_auth_enabled: true,
          cli_session_ttl_days: @fallback_session_ttl_days,
          cli_allowed_scopes: @fallback_allowed_scopes
        }
    end
  end

  defp enforce_cli_auth_enabled(%{cli_auth_enabled: false}), do: {:error, :cli_auth_disabled}
  defp enforce_cli_auth_enabled(_), do: :ok

  defp parse_scopes(nil), do: []

  defp parse_scopes(scope) when is_binary(scope), do: String.split(scope, ~r/[\s,]+/, trim: true)

  defp scope_to_atom(scope) when is_atom(scope), do: scope
  defp scope_to_atom(scope) when is_binary(scope), do: String.to_atom(scope)
  defp scope_to_atom(_), do: :read

  ## Code generation

  defp generate_device_code do
    plaintext = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    {plaintext, sha256_hex(plaintext)}
  end

  defp generate_user_code do
    {first, second} = {random_block(4), random_block(4)}
    "#{first}-#{second}"
  end

  defp random_block(length) do
    1..length
    |> Enum.map(fn _ -> Enum.random(@user_code_alphabet) end)
    |> List.to_string()
  end

  defp sha256_hex(value) do
    :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)
  end

  defp unix_to_dt(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp unix_to_dt(_), do: nil

  ## Response helpers

  defp build_verification_uri(conn) do
    "#{request_origin(conn)}/cli/auth/device"
  end

  defp request_origin(%Plug.Conn{} = conn) do
    scheme =
      case get_req_header(conn, "x-forwarded-proto") do
        [proto | _] when proto in ["http", "https"] -> proto
        _ -> Atom.to_string(conn.scheme)
      end

    host =
      case get_req_header(conn, "x-forwarded-host") do
        [forwarded | _] when byte_size(forwarded) > 0 -> forwarded
        _ -> conn.host
      end

    port_part =
      case conn.port do
        80 when scheme == "http" -> ""
        443 when scheme == "https" -> ""
        port when is_integer(port) -> ":#{port}"
        _ -> ""
      end

    "#{scheme}://#{host}#{port_part}"
  end

  defp error_response(conn, status, error, description) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> send_resp(
      status,
      Jason.encode!(%{
        error: error,
        error_description: description
      })
    )
  end
end
