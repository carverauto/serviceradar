defmodule ServiceRadarWebNG.Auth.TokenRevocation do
  @moduledoc """
  Token revocation service for invalidating compromised sessions.
  """

  use GenServer

  require Logger

  @table :revoked_tokens
  @store_table :revoked_tokens_store
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

    GenServer.call(__MODULE__, {:persist, entry})
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

    GenServer.call(__MODULE__, {:persist, entry})
  end

  @spec check_user_revoked(String.t(), DateTime.t() | integer() | binary() | nil) ::
          :ok | {:error, :user_revoked}
  def check_user_revoked(_user_id, nil), do: :ok

  def check_user_revoked(user_id, issued_at) when is_binary(user_id) do
    marker_jti = "user:#{user_id}:all"

    case :ets.lookup(@table, marker_jti) do
      [{^marker_jti, %{revoked_before: revoked_before}}] ->
        check_revoked_before(issued_at, revoked_before, user_id)

      [] ->
        :ok
    end
  end

  @spec check_user_tokens_revoked(String.t(), DateTime.t() | integer() | binary() | nil) ::
          :ok | {:error, :user_revoked}
  def check_user_tokens_revoked(user_id, issued_at), do: check_user_revoked(user_id, issued_at)

  @spec get_revocation_info(String.t()) :: {:ok, map()} | :not_found
  def get_revocation_info(jti) when is_binary(jti) do
    case :ets.lookup(@table, jti) do
      [{^jti, entry}] -> {:ok, entry}
      [] -> :not_found
    end
  end

  @spec clear_revocation(String.t()) :: :ok
  def clear_revocation(jti) when is_binary(jti) do
    GenServer.call(__MODULE__, {:clear, jti})
  end

  @impl true
  def init(_opts) do
    reset_cache_table()

    {:ok, store} = open_store()
    load_store_into_cache(store)

    state = %{store: store}
    cleanup_expired_entries(state)
    schedule_cleanup()
    {:ok, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired_entries(state)
    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_call({:persist, entry}, _from, state) do
    persist_entry(state.store, entry)
    Logger.info("Token revoked", jti: entry.jti, user_id: entry.user_id, reason: entry.reason)
    {:reply, :ok, state}
  end

  def handle_call({:clear, jti}, _from, state) do
    :ets.delete(@table, jti)
    :ok = :dets.delete(state.store, jti)
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, %{store: store}) do
    :dets.close(store)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp default_ttl_ms, do: @default_ttl_seconds * 1000

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp reset_cache_table do
    case :ets.whereis(@table) do
      :undefined -> :ok
      tid -> :ets.delete(tid)
    end

    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
  end

  defp open_store do
    store_path = store_path()
    File.mkdir_p!(Path.dirname(store_path))

    case :dets.open_file(@store_table, type: :set, file: String.to_charlist(store_path)) do
      {:ok, store} ->
        {:ok, store}

      {:error, reason} ->
        raise "failed to open token revocation store: #{inspect(reason)}"
    end
  end

  defp store_path do
    :serviceradar_web_ng
    |> Application.get_env(:token_revocation, [])
    |> Keyword.get(:store_path, "/var/lib/serviceradar/auth/revoked_tokens.dets")
  end

  defp load_store_into_cache(store) do
    now = System.system_time(:millisecond)

    :dets.foldl(
      fn {jti, entry}, :ok ->
        if expired?(entry, now) do
          :ok = :dets.delete(store, jti)
        else
          :ets.insert(@table, {jti, entry})
        end

        :ok
      end,
      :ok,
      store
    )
  end

  defp cleanup_expired_entries(state) do
    now = System.system_time(:millisecond)

    expired_keys =
      :ets.foldl(
        fn {jti, entry}, acc ->
          if expired?(entry, now), do: [jti | acc], else: acc
        end,
        [],
        @table
      )

    Enum.each(expired_keys, fn jti ->
      :ets.delete(@table, jti)
      :ok = :dets.delete(state.store, jti)
    end)
  end

  defp expired?(%{expires_at: expires_at}, now) when is_integer(expires_at), do: expires_at < now
  defp expired?(_entry, _now), do: false

  defp persist_entry(store, entry) do
    :ets.insert(@table, {entry.jti, entry})
    :ok = :dets.insert(store, {entry.jti, entry})
  end

  defp check_revoked_before(issued_at, revoked_before, user_id) do
    case normalize_issued_at(issued_at) do
      {:ok, issued_at_dt} ->
        if DateTime.before?(issued_at_dt, revoked_before) do
          {:error, :user_revoked}
        else
          :ok
        end

      :error ->
        Logger.warning(
          "Unable to normalize token issued_at for revocation check: " <>
            "issued_at=#{inspect(issued_at)} user_id=#{user_id}"
        )

        {:error, :user_revoked}
    end
  end

  defp normalize_issued_at(%DateTime{} = issued_at), do: {:ok, issued_at}

  defp normalize_issued_at(issued_at) when is_integer(issued_at) do
    DateTime.from_unix(issued_at)
  end

  defp normalize_issued_at(issued_at) when is_float(issued_at) do
    issued_at
    |> trunc()
    |> DateTime.from_unix()
  end

  defp normalize_issued_at(issued_at) when is_binary(issued_at) do
    case Integer.parse(issued_at) do
      {unix, ""} -> DateTime.from_unix(unix)
      _ -> :error
    end
  end

  defp normalize_issued_at(_issued_at), do: :error
end
