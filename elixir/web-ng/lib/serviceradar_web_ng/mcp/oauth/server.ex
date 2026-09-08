defmodule ServiceRadarWebNG.Mcp.OAuth.Server do
  @moduledoc """
  Issues MCP authorization codes, access tokens, and rotating refresh tokens.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.Constants
  alias ServiceRadar.Identity.McpOAuthCode
  alias ServiceRadar.Identity.McpOAuthGrant
  alias ServiceRadar.Identity.McpOAuthRefreshToken
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.User
  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNG.Mcp.OAuth
  alias ServiceRadarWebNG.Mcp.OAuth.Audit
  alias ServiceRadarWebNG.Mcp.OAuth.IdPSession
  alias ServiceRadarWebNG.Mcp.OAuth.Pkce
  alias ServiceRadarWebNG.Mcp.OAuth.RedirectURI

  @actor SystemActor.system(:oauth_token)

  @spec can_issue_refresh?(McpOAuthGrant.t()) :: boolean()
  def can_issue_refresh?(%McpOAuthGrant{auth_method: :password}), do: true

  def can_issue_refresh?(%McpOAuthGrant{auth_method: method} = grant) when method in [:oidc, :saml] do
    is_binary(grant.idp_refresh_token) and grant.idp_refresh_token != ""
  end

  def can_issue_refresh?(_), do: false

  @spec active_grant?(User.t(), String.t()) :: boolean()
  def active_grant?(user, client_id) when is_binary(client_id) do
    match?({:ok, %McpOAuthGrant{}}, McpOAuthGrant.active_for(user.id, client_id, actor: @actor))
  end

  def active_grant?(_, _), do: false

  @spec complete_authorization(User.t(), map(), map()) ::
          {:ok, McpOAuthGrant.t(), String.t()} | {:error, term()}
  def complete_authorization(%User{} = user, request, idp) when is_map(request) and is_map(idp) do
    if RBAC.has_permission?(user, Constants.mcp_manage_permission()) do
      do_complete_authorization(user, request, idp)
    else
      {:error, :forbidden}
    end
  end

  defp do_complete_authorization(user, request, idp) do
    attrs =
      idp
      |> Map.take([:auth_method, :idp_iss, :idp_sid, :idp_refresh_token])
      |> Map.put(:client_id, request["client_id"])
      |> Map.put(:scope, request["scope"])

    with {:ok, grant} <- upsert_grant(user, attrs),
         {:ok, code} <-
           issue_code(grant, %{
             redirect_uri: request["redirect_uri"],
             code_challenge: request["code_challenge"]
           }) do
      Audit.authorize_approved(
        actor_id: user.id,
        client_id: request["client_id"],
        scope: request["scope"],
        idp_sid: idp[:idp_sid],
        route: "/oauth/consent"
      )

      {:ok, grant, RedirectURI.append_query(request["redirect_uri"], %{"code" => code, "state" => request["state"]})}
    end
  end

  @spec upsert_grant(User.t(), map()) :: {:ok, McpOAuthGrant.t()} | {:error, term()}
  def upsert_grant(user, attrs) do
    client_id = Map.fetch!(attrs, :client_id)
    scope = Map.fetch!(attrs, :scope)

    case McpOAuthGrant.active_for(user.id, client_id, actor: @actor) do
      {:ok, %McpOAuthGrant{} = grant} ->
        McpOAuthGrant.bind_idp(grant, bind_idp_attrs(grant, attrs), actor: @actor)

      _ ->
        create_grant(user, attrs, scope)
    end
  end

  defp bind_idp_attrs(grant, attrs) do
    maybe_put_refresh(
      %{
        auth_method: Map.get(attrs, :auth_method, grant.auth_method),
        idp_iss: Map.get(attrs, :idp_iss) || grant.idp_iss,
        idp_sid: Map.get(attrs, :idp_sid) || grant.idp_sid
      },
      Map.get(attrs, :idp_refresh_token)
    )
  end

  defp maybe_put_refresh(attrs, token) when is_binary(token) and token != "",
    do: Map.put(attrs, :idp_refresh_token, token)

  defp maybe_put_refresh(attrs, _), do: attrs

  defp create_grant(user, attrs, scope) do
    McpOAuthGrant.create(
      %{
        user_id: user.id,
        client_id: Map.fetch!(attrs, :client_id),
        scope: scope,
        auth_method: Map.get(attrs, :auth_method, :password),
        idp_iss: Map.get(attrs, :idp_iss),
        idp_sid: Map.get(attrs, :idp_sid),
        idp_refresh_token: Map.get(attrs, :idp_refresh_token)
      },
      actor: @actor
    )
  end

  @spec issue_code(McpOAuthGrant.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def issue_code(%McpOAuthGrant{} = grant, %{redirect_uri: redirect_uri, code_challenge: challenge}) do
    plaintext = OAuth.random_token()

    case McpOAuthCode.create(
           %{
             grant_id: grant.id,
             user_id: grant.user_id,
             client_id: grant.client_id,
             code_hash: OAuth.sha256_hex(plaintext),
             redirect_uri: redirect_uri,
             code_challenge: challenge,
             scope: grant.scope,
             expires_at: DateTime.add(DateTime.utc_now(), OAuth.code_ttl_seconds(), :second)
           },
           actor: @actor
         ) do
      {:ok, _code} -> {:ok, plaintext}
      other -> other
    end
  end

  @spec exchange_code(map()) :: {:ok, map()} | {:error, atom()}
  def exchange_code(params) do
    with {:ok, client_id} <- require_public_client(params["client_id"]),
         {:ok, code} <- require_binary(params["code"]),
         {:ok, redirect_uri} <- require_binary(params["redirect_uri"]),
         {:ok, verifier} <- require_binary(params["code_verifier"]),
         {:ok, record} <- fetch_code(code),
         :ok <- validate_code(record, client_id, redirect_uri, verifier),
         {:ok, grant} <- McpOAuthGrant.get_by_id(record.grant_id, actor: @actor),
         {:ok, user} <- User.get_by_id(grant.user_id, actor: @actor),
         {:ok, _} <- McpOAuthCode.consume(record, actor: @actor),
         {:ok, tokens} <- issue_tokens(user, grant) do
      Audit.token_issued(
        actor_id: user.id,
        client_id: client_id,
        scope: grant.scope,
        route: "/oauth/token"
      )

      {:ok, tokens}
    end
  end

  @spec refresh(map()) :: {:ok, map()} | {:error, atom()}
  def refresh(params) do
    with {:ok, plaintext} <- require_binary(params["refresh_token"]),
         {:ok, record} <- fetch_refresh(plaintext),
         :ok <- validate_refresh(record),
         {:ok, grant} <- McpOAuthGrant.get_by_id(record.grant_id, actor: @actor),
         :ok <- ensure_grant_active(grant),
         :ok <- ensure_idp_session(grant),
         {:ok, user} <- User.get_by_id(grant.user_id, actor: @actor),
         {:ok, tokens} <- rotate_refresh(user, grant, record) do
      Audit.refreshed(actor_id: user.id, client_id: grant.client_id, scope: grant.scope)
      {:ok, tokens}
    end
  end

  @spec revoke_grant(McpOAuthGrant.t()) :: :ok
  def revoke_grant(%McpOAuthGrant{} = grant) do
    _ = McpOAuthGrant.revoke(grant, actor: @actor)
    revoke_family(grant.id)
    Audit.grant_revoked(actor_id: grant.user_id, client_id: grant.client_id)
    :ok
  end

  @spec revoke_by_idp_sid(String.t(), String.t()) :: :ok
  def revoke_by_idp_sid(iss, sid) when is_binary(iss) and is_binary(sid) do
    case McpOAuthGrant.by_idp_sid(iss, sid, actor: @actor) do
      {:ok, grants} ->
        Enum.each(grants, fn grant ->
          revoke_grant(grant)
          Audit.slo_revoked(actor_id: grant.user_id, client_id: grant.client_id, idp_sid: sid)
        end)

      _ ->
        :ok
    end
  end

  def revoke_by_idp_sid(_, _), do: :ok

  defp fetch_code(plaintext) do
    case McpOAuthCode.get_by_code_hash(OAuth.sha256_hex(plaintext), actor: @actor) do
      {:ok, record} -> {:ok, record}
      _ -> {:error, :invalid_grant}
    end
  end

  defp validate_code(record, client_id, redirect_uri, verifier) do
    now = DateTime.utc_now()

    cond do
      record.consumed_at != nil -> {:error, :invalid_grant}
      DateTime.compare(record.expires_at, now) != :gt -> {:error, :invalid_grant}
      record.client_id != client_id -> {:error, :invalid_grant}
      record.redirect_uri != redirect_uri -> {:error, :invalid_grant}
      not Pkce.valid_s256?(verifier, record.code_challenge) -> {:error, :invalid_grant}
      true -> :ok
    end
  end

  defp fetch_refresh(plaintext) do
    case McpOAuthRefreshToken.get_by_token_hash(OAuth.sha256_hex(plaintext), actor: @actor) do
      {:ok, record} -> {:ok, record}
      _ -> {:error, :invalid_grant}
    end
  end

  defp validate_refresh(record) do
    now = DateTime.utc_now()

    cond do
      record.revoked_at != nil ->
        revoke_family_tokens(record.family_id)
        Audit.refresh_reuse(client_id: record.client_id, actor_id: record.user_id)
        {:error, :invalid_grant}

      DateTime.compare(record.expires_at, now) != :gt ->
        {:error, :invalid_grant}

      true ->
        :ok
    end
  end

  defp ensure_grant_active(%McpOAuthGrant{revoked_at: nil}), do: :ok
  defp ensure_grant_active(_), do: {:error, :invalid_grant}

  defp ensure_idp_session(%McpOAuthGrant{auth_method: :password}), do: :ok

  defp ensure_idp_session(%McpOAuthGrant{} = grant) do
    case IdPSession.check(grant) do
      {:ok, new_refresh} when is_binary(new_refresh) and new_refresh != "" ->
        _ = McpOAuthGrant.bind_idp(grant, %{idp_refresh_token: new_refresh}, actor: @actor)
        :ok

      {:ok, _} ->
        :ok

      _ ->
        revoke_grant(grant)

        Audit.idp_refresh_denied(
          actor_id: grant.user_id,
          client_id: grant.client_id,
          idp_sid: grant.idp_sid
        )

        {:error, :invalid_grant}
    end
  end

  defp issue_tokens(user, grant) do
    with {:ok, access, claims} <- mint_access(user, grant) do
      if can_issue_refresh?(grant) do
        family_id = Ecto.UUID.generate()

        case insert_refresh(grant, family_id) do
          {:ok, plaintext} ->
            {:ok, token_response(access, claims, grant.scope, plaintext)}

          error ->
            error
        end
      else
        {:ok, token_response(access, claims, grant.scope, nil)}
      end
    end
  end

  defp rotate_refresh(user, grant, current) do
    with {:ok, access, claims} <- mint_access(user, grant),
         {:ok, plaintext} <- insert_refresh(grant, current.family_id),
         {:ok, _} <- McpOAuthRefreshToken.revoke(current, actor: @actor) do
      {:ok, token_response(access, claims, grant.scope, plaintext)}
    end
  end

  defp insert_refresh(grant, family_id) do
    plaintext = OAuth.random_token()
    ttl = OAuth.refresh_ttl_seconds()

    case McpOAuthRefreshToken.create(
           %{
             family_id: family_id,
             grant_id: grant.id,
             user_id: grant.user_id,
             client_id: grant.client_id,
             token_hash: OAuth.sha256_hex(plaintext),
             scope: grant.scope,
             expires_at: DateTime.add(DateTime.utc_now(), ttl, :second)
           },
           actor: @actor
         ) do
      {:ok, _} -> {:ok, plaintext}
      error -> error
    end
  end

  defp mint_access(user, grant) do
    scopes =
      grant.scope
      |> String.split(~r/\s+/, trim: true)
      |> Enum.map(&ServiceRadarWebNG.Api.OauthScopes.to_atom/1)

    extra = %{
      "client_id" => grant.client_id,
      "scope" => grant.scope
    }

    Guardian.create_api_token(user,
      scopes: scopes,
      claims: extra,
      ttl: {OAuth.access_ttl_seconds(), :second}
    )
  end

  defp token_response(access, _claims, scope, nil) do
    %{
      access_token: access,
      token_type: "Bearer",
      expires_in: OAuth.access_ttl_seconds(),
      scope: scope
    }
  end

  defp token_response(access, claims, scope, refresh) do
    access
    |> token_response(claims, scope, nil)
    |> Map.put(:refresh_token, refresh)
  end

  defp revoke_family(grant_id) do
    case McpOAuthRefreshToken.list_by_grant(grant_id, actor: @actor) do
      {:ok, rows} -> Enum.each(rows, &McpOAuthRefreshToken.revoke(&1, actor: @actor))
      _ -> :ok
    end
  end

  defp revoke_family_tokens(family_id) do
    case McpOAuthRefreshToken.list_by_family(family_id, actor: @actor) do
      {:ok, rows} -> Enum.each(rows, &McpOAuthRefreshToken.revoke(&1, actor: @actor))
      _ -> :ok
    end
  end

  defp require_public_client(id) when id == "serviceradar-mcp", do: {:ok, id}
  defp require_public_client(_), do: {:error, :invalid_client}

  defp require_binary(value) when is_binary(value) and value != "", do: {:ok, value}
  defp require_binary(_), do: {:error, :invalid_request}
end
