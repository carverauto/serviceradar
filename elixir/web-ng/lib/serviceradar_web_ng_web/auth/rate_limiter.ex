defmodule ServiceRadarWebNGWeb.Auth.RateLimiter do
  @moduledoc """
  Thin backwards-compatible shim over `ServiceRadar.Security.RateLimiter`.

  The original module was a single-node ETS limiter, which silently
  diverges across the web-ng ReplicaSet (the demo namespace runs
  three pods). This shim preserves the public API so existing
  controllers and LiveViews keep working unchanged while the shared,
  cluster-aware limiter handles the actual bookkeeping. Prefer
  `ServiceRadar.Security.RateLimiter` (or `ServiceRadarWebNGWeb.Plugs.RateLimit`)
  directly in new code.
  """

  alias ServiceRadar.Security.RateLimiter

  @spec check_rate_limit(String.t() | atom(), term(), keyword()) ::
          :ok | {:error, pos_integer()}
  def check_rate_limit(action, key, opts \\ []) do
    RateLimiter.check(action, key, opts)
  end

  @spec record_attempt(String.t() | atom(), term()) :: :ok
  def record_attempt(action, key) do
    RateLimiter.record(action, key)
  end

  @spec check_rate_limit_and_record(String.t() | atom(), term(), keyword()) ::
          :ok | {:error, pos_integer()}
  def check_rate_limit_and_record(action, key, opts \\ []) do
    RateLimiter.check_and_record(action, key, opts)
  end

  @spec clear_rate_limit(String.t() | atom(), term()) :: :ok
  def clear_rate_limit(action, key) do
    RateLimiter.clear(action, key)
  end
end
