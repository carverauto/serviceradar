defmodule ServiceRadarWebNG.Auth.CliSessions do
  @moduledoc """
  CLI session management context for the Settings UI.

  Wraps `ServiceRadar.Identity.CliSession` reads + the revoke flow.
  Revoke flips the metadata row to `:revoked` *and* writes a
  `ServiceRadar.Identity.RevokedToken` entry via
  `ServiceRadarWebNG.Auth.TokenRevocation` so the existing Guardian
  verify hook (`Guardian.verify_not_revoked/1`) rejects the JWT on the
  next API request the holder makes.

  All calls require an actor; the LiveView passes the current scope's
  user. Read paths obey the `cli.session.read_*` policies on the
  resource; revoke obeys `cli.session.revoke_*`.
  """

  alias ServiceRadar.Identity.CliSession
  alias ServiceRadarWebNG.Auth.TokenRevocation

  require Logger

  @doc """
  Active CLI sessions for the given user.
  """
  @spec list_active_for_user(binary(), keyword()) :: {:ok, [CliSession.t()]} | {:error, term()}
  def list_active_for_user(user_id, opts \\ []) when is_binary(user_id) do
    actor = Keyword.fetch!(opts, :actor)
    CliSession.list_active_by_user(user_id, actor: actor)
  end

  @doc """
  Every CLI session — admin-only via `cli.session.read_any`.
  """
  @spec list_all(keyword()) :: {:ok, [CliSession.t()]} | {:error, term()}
  def list_all(opts) do
    actor = Keyword.fetch!(opts, :actor)
    CliSession.list_all(actor: actor)
  end

  @doc """
  Revoke a single CLI session.

  Flips the metadata row's status + stamps revoked_at/by, then writes a
  matching token revocation so the JWT itself is rejected on the next
  API request. Returns the updated `CliSession` record.
  """
  @spec revoke(CliSession.t(), keyword()) ::
          {:ok, CliSession.t()} | {:error, term()}
  def revoke(%CliSession{} = session, opts) do
    actor = Keyword.fetch!(opts, :actor)
    revoked_by = revoked_by_label(actor)

    case CliSession.revoke(session, revoked_by, actor: actor) do
      {:ok, updated} ->
        ensure_jti_revoked(updated)
        {:ok, updated}

      {:error, _reason} = error ->
        error
    end
  end

  defp ensure_jti_revoked(%CliSession{jti: jti, user_id: user_id, expires_at: expires_at}) do
    ttl_ms = ttl_until_expiry(expires_at)

    case TokenRevocation.revoke_token(jti,
           reason: :cli_session_revoked,
           user_id: user_id,
           ttl: ttl_ms
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        # The metadata flip succeeded but the JWT denylist write failed.
        # Surface the inconsistency so an operator can retry — the
        # session row will read as :revoked in the Settings UI but the
        # JWT will keep validating until the GenServer comes back. The
        # daily cleanup worker (proposal §8) re-asserts revoked rows so
        # this self-heals.
        Logger.warning(
          "CLI session metadata revoked but JWT denylist write failed",
          jti: jti,
          user_id: user_id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp ttl_until_expiry(%DateTime{} = expires_at) do
    diff = DateTime.diff(expires_at, DateTime.utc_now(), :millisecond)
    max(diff, 60_000)
  end

  defp ttl_until_expiry(_), do: 30 * 24 * 60 * 60 * 1000

  defp revoked_by_label(%{id: id}) when is_binary(id), do: id
  defp revoked_by_label(_), do: "system"
end
