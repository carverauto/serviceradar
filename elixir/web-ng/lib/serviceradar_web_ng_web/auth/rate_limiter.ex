defmodule ServiceRadarWebNGWeb.Auth.RateLimiter do
  @moduledoc """
  Simple ETS-based rate limiter for authentication endpoints.

  Provides sliding window rate limiting to prevent brute force attacks
  on authentication endpoints, particularly the local admin backdoor.

  ## Configuration

  Rate limits are configured per-action:
  - `local_auth`: 5 attempts per minute per IP

  ## Usage

      case RateLimiter.check_rate_limit("local_auth", client_ip) do
        :ok -> proceed_with_auth()
        {:error, retry_after} -> show_rate_limit_error(retry_after)
      end

  After a successful or failed attempt:

      RateLimiter.record_attempt("local_auth", client_ip)
  """

  use GenServer

  require Logger

  @table :auth_rate_limiter
  @cleanup_interval to_timeout(minute: 5)

  # Default limits
  @default_limit 5
  @default_window_seconds 60

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if an action is rate limited for a given key (usually IP address).

  Returns `:ok` if under the limit, or `{:error, retry_after_seconds}` if limited.

  ## Options

  - `:limit` - Maximum attempts allowed (default: 5)
  - `:window_seconds` - Time window in seconds (default: 60)
  """
  @spec check_rate_limit(String.t(), String.t(), keyword()) :: :ok | {:error, pos_integer()}
  def check_rate_limit(action, key, opts \\ []) do
    GenServer.call(__MODULE__, {:check_rate_limit, action, key, opts})
  end

  @doc """
  Record an authentication attempt for rate limiting.

  Call this after each login attempt (success or failure).
  """
  @spec record_attempt(String.t(), String.t()) :: :ok
  def record_attempt(action, key) do
    GenServer.call(__MODULE__, {:record_attempt, action, key})
  end

  @doc """
  Atomically checks the current rate limit window and records the attempt when allowed.
  """
  @spec check_rate_limit_and_record(String.t(), String.t(), keyword()) ::
          :ok | {:error, pos_integer()}
  def check_rate_limit_and_record(action, key, opts \\ []) do
    GenServer.call(__MODULE__, {:check_rate_limit_and_record, action, key, opts})
  end

  @doc """
  Clear rate limit for a specific action/key combination.

  Useful for testing or manual intervention.
  """
  @spec clear_rate_limit(String.t(), String.t()) :: :ok
  def clear_rate_limit(action, key) do
    :ets.delete(@table, {action, key})
    :ok
  end

  ## Server Callbacks

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

  @impl true
  def handle_call({:check_rate_limit, action, key, opts}, _from, state) do
    {:reply, do_check_rate_limit(action, key, opts), state}
  end

  def handle_call({:record_attempt, action, key}, _from, state) do
    do_record_attempt(action, key)
    {:reply, :ok, state}
  end

  def handle_call({:check_rate_limit_and_record, action, key, opts}, _from, state) do
    result =
      case do_check_rate_limit(action, key, opts) do
        :ok ->
          do_record_attempt(action, key)
          :ok

        {:error, _retry_after} = error ->
          error
      end

    {:reply, result, state}
  end

  ## Private Functions

  defp do_check_rate_limit(action, key, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    window_seconds = Keyword.get(opts, :window_seconds, @default_window_seconds)
    cache_key = {action, key}
    now = System.system_time(:second)
    window_start = now - window_seconds
    attempts = get_attempts(cache_key, window_start)

    if length(attempts) >= limit do
      oldest = Enum.min(attempts, fn -> now end)
      {:error, max(1, oldest + window_seconds - now)}
    else
      :ok
    end
  end

  defp do_record_attempt(action, key) do
    cache_key = {action, key}
    now = System.system_time(:second)
    attempts = get_attempts(cache_key, 0)
    :ets.insert(@table, {cache_key, [now | attempts]})
    :ok
  end

  defp get_attempts(cache_key, window_start) do
    case :ets.lookup(@table, cache_key) do
      [{^cache_key, attempts}] ->
        # Filter to only attempts within the window
        Enum.filter(attempts, &(&1 >= window_start))

      [] ->
        []
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp cleanup_expired_entries do
    now = System.system_time(:second)
    # Keep entries from the last 5 minutes (generous window)
    cutoff = now - 300

    # Get all keys and clean up old entries
    :ets.foldl(
      fn {key, attempts}, acc ->
        filtered = Enum.filter(attempts, &(&1 >= cutoff))

        if Enum.empty?(filtered) do
          :ets.delete(@table, key)
        else
          :ets.insert(@table, {key, filtered})
        end

        acc
      end,
      :ok,
      @table
    )
  end
end
