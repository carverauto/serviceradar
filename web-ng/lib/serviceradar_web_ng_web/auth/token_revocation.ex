defmodule ServiceRadarWebNGWeb.Auth.TokenRevocation do
  @moduledoc """
  Token revocation service for invalidating compromised sessions.

  Maintains an ETS-based list of revoked token IDs (JTIs) that are checked
  during token verification. Revoked tokens are rejected even if they haven't
  expired.

  ## Usage

      # Revoke a token
      TokenRevocation.revoke_token(jti, reason: "user_logout")

      # Check if a token is revoked
      case TokenRevocation.check_revoked(jti) do
        :ok -> # Token is valid
        {:error, :revoked} -> # Token has been revoked
      end

      # Revoke all tokens for a user
      TokenRevocation.revoke_all_for_user(user_id)

  ## Cleanup

  Revoked tokens are automatically cleaned up after they would have expired
  (default: 24 hours) to prevent unbounded memory growth.
  """

  use GenServer

  require Logger

  @table :revoked_tokens
  @cleanup_interval :timer.hours(1)
  @default_ttl :timer.hours(24)

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Revoke a specific token by its JTI (JWT ID).

  Options:
  - `:reason` - Reason for revocation (for audit logging)
  - `:user_id` - User ID associated with the token
  - `:ttl` - How long to keep the revocation record (default: 24h)
  """
  @spec revoke_token(String.t(), keyword()) :: :ok
  def revoke_token(jti, opts \\ []) when is_binary(jti) do
    reason = Keyword.get(opts, :reason, :manual)
    user_id = Keyword.get(opts, :user_id)
    ttl = Keyword.get(opts, :ttl, @default_ttl)

    expires_at = System.system_time(:millisecond) + ttl

    entry = %{
      jti: jti,
      user_id: user_id,
      reason: reason,
      revoked_at: DateTime.utc_now(),
      expires_at: expires_at
    }

    :ets.insert(@table, {jti, entry})

    Logger.info("Token revoked",
      jti: jti,
      user_id: user_id,
      reason: reason
    )

    :ok
  end

  @doc """
  Check if a token has been revoked.

  Returns `:ok` if the token is valid, `{:error, :revoked}` if revoked.
  """
  @spec check_revoked(String.t() | nil) :: :ok | {:error, :revoked}
  def check_revoked(nil), do: :ok

  def check_revoked(jti) when is_binary(jti) do
    case :ets.lookup(@table, jti) do
      [{^jti, _entry}] -> {:error, :revoked}
      [] -> :ok
    end
  end

  @doc """
  Revoke all tokens for a specific user.

  This is useful when a user's account is compromised or when
  they change their password.
  """
  @spec revoke_all_for_user(String.t(), keyword()) :: :ok
  def revoke_all_for_user(user_id, opts \\ []) when is_binary(user_id) do
    reason = Keyword.get(opts, :reason, :user_tokens_revoked)

    # Store a marker that all tokens for this user before now are revoked
    marker_jti = "user:#{user_id}:all"
    revoked_before = DateTime.utc_now()

    entry = %{
      jti: marker_jti,
      user_id: user_id,
      reason: reason,
      revoked_at: revoked_before,
      revoked_before: revoked_before,
      expires_at: System.system_time(:millisecond) + @default_ttl
    }

    :ets.insert(@table, {marker_jti, entry})

    Logger.info("All tokens revoked for user",
      user_id: user_id,
      reason: reason
    )

    :ok
  end

  @doc """
  Check if a user's tokens issued before a certain time are revoked.

  Used in conjunction with `revoke_all_for_user/2`.
  """
  @spec check_user_tokens_revoked(String.t(), DateTime.t() | integer()) ::
          :ok | {:error, :revoked}
  def check_user_tokens_revoked(user_id, issued_at) when is_binary(user_id) do
    marker_jti = "user:#{user_id}:all"

    case :ets.lookup(@table, marker_jti) do
      [{^marker_jti, %{revoked_before: revoked_before}}] ->
        # Convert issued_at to DateTime if it's a unix timestamp
        issued_datetime =
          case issued_at do
            %DateTime{} = dt -> dt
            ts when is_integer(ts) -> DateTime.from_unix!(ts)
          end

        if DateTime.compare(issued_datetime, revoked_before) == :lt do
          {:error, :revoked}
        else
          :ok
        end

      [] ->
        :ok
    end
  end

  @doc """
  Get revocation info for a token, if revoked.
  """
  @spec get_revocation_info(String.t()) :: {:ok, map()} | :not_found
  def get_revocation_info(jti) when is_binary(jti) do
    case :ets.lookup(@table, jti) do
      [{^jti, entry}] -> {:ok, entry}
      [] -> :not_found
    end
  end

  @doc """
  Clear a revocation (un-revoke a token).

  Use with caution - typically only for testing or error correction.
  """
  @spec clear_revocation(String.t()) :: :ok
  def clear_revocation(jti) when is_binary(jti) do
    :ets.delete(@table, jti)
    Logger.info("Token revocation cleared", jti: jti)
    :ok
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table
    :ets.new(@table, [:named_table, :public, :set])

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired_entries()
    schedule_cleanup()
    {:noreply, state}
  end

  # Private Functions

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp cleanup_expired_entries do
    now = System.system_time(:millisecond)

    # Get all expired entries and delete them
    expired_count =
      :ets.foldl(
        fn {jti, %{expires_at: expires_at}}, count ->
          if expires_at < now do
            :ets.delete(@table, jti)
            count + 1
          else
            count
          end
        end,
        0,
        @table
      )

    if expired_count > 0 do
      Logger.debug("Cleaned up #{expired_count} expired token revocations")
    end
  end
end
