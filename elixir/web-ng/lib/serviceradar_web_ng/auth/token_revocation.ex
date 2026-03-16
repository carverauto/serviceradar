defmodule ServiceRadarWebNG.Auth.TokenRevocation do
  @moduledoc """
  Token revocation service for invalidating compromised sessions.
  """

  use GenServer

  require Logger

  @table :revoked_tokens
  @cleanup_interval to_timeout(hour: 1)
  @default_ttl_seconds 30 * 24 * 60 * 60

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec revoke_token(String.t(), keyword()) :: :ok
  def revoke_token(jti, opts \\ []) when is_binary(jti) do
    reason = Keyword.get(opts, :reason, :manual)
    user_id = Keyword.get(opts, :user_id)
    ttl = Keyword.get(opts, :ttl, default_ttl_ms())

    expires_at = System.system_time(:millisecond) + ttl

    entry = %{
      jti: jti,
      user_id: user_id,
      reason: reason,
      revoked_at: DateTime.utc_now(),
      expires_at: expires_at
    }

    :ets.insert(@table, {jti, entry})

    Logger.info("Token revoked", jti: jti, user_id: user_id, reason: reason)
    :ok
  end

  @spec check_revoked(String.t() | nil) :: :ok | {:error, :revoked}
  def check_revoked(nil), do: :ok

  def check_revoked(jti) when is_binary(jti) do
    case :ets.lookup(@table, jti) do
      [{^jti, _entry}] -> {:error, :revoked}
      [] -> :ok
    end
  end

  @spec revoke_all_for_user(String.t(), keyword()) :: :ok
  def revoke_all_for_user(user_id, opts \\ []) when is_binary(user_id) do
    reason = Keyword.get(opts, :reason, :user_tokens_revoked)
    marker_jti = "user:#{user_id}:all"
    revoked_before = DateTime.utc_now()

    entry = %{
      jti: marker_jti,
      user_id: user_id,
      reason: reason,
      revoked_at: revoked_before,
      revoked_before: revoked_before,
      expires_at: System.system_time(:millisecond) + default_ttl_ms()
    }

    :ets.insert(@table, {marker_jti, entry})

    Logger.info("All tokens revoked for user", user_id: user_id, reason: reason)
    :ok
  end

  @spec check_user_revoked(String.t(), DateTime.t() | nil) :: :ok | {:error, :user_revoked}
  def check_user_revoked(_user_id, nil), do: :ok

  def check_user_revoked(user_id, issued_at) when is_binary(user_id) do
    marker_jti = "user:#{user_id}:all"

    case :ets.lookup(@table, marker_jti) do
      [{^marker_jti, %{revoked_before: revoked_before}}] ->
        if DateTime.before?(issued_at, revoked_before) do
          {:error, :user_revoked}
        else
          :ok
        end

      [] ->
        :ok
    end
  end

  @impl true
  def init(_opts) do
    table_opts = [:named_table, :public, :set, read_concurrency: true]
    :ets.new(@table, table_opts)
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.system_time(:millisecond)

    :ets.select_delete(@table, [
      {{:"$1", %{expires_at: :"$2"}}, [{:<, :"$2", now}], [true]}
    ])

    schedule_cleanup()
    {:noreply, state}
  end

  defp default_ttl_ms, do: @default_ttl_seconds * 1000

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
