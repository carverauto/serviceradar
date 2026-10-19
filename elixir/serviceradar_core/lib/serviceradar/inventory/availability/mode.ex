defmodule ServiceRadar.Inventory.Availability.Mode do
  @moduledoc """
  The deployment's availability mode (`inventory.availability_mode`, design Decision 10)
  and the operator switch between `legacy` and `shadow`.

  `cached/0` is the gate inline resolution checks on every write path. It reads the
  mode from this node's cache, refreshed at most every 30 seconds
  (`config :serviceradar_core, #{inspect(__MODULE__)}, cache_ms: ...`), so in `legacy` a
  sweep or evidence write issues no query for availability. Writers that pass the gate
  re-read the mode inside their own transaction (`current/1`) before resolving.

  ## Switching

  The switch is an operator action:

      bin/serviceradar_core rpc 'ServiceRadar.Inventory.Availability.Mode.enter_shadow() |> IO.inspect()'
      mix serviceradar.availability.mode shadow

  `enter_shadow/0` moves `legacy` to `shadow`, starts the expiry window, and enqueues one
  full, paged resolution of every device plus the seeding of the compatibility table
  (`ServiceRadar.Inventory.Availability.ShadowEntryWorker`); the invalidation log is
  empty in `legacy`, so nothing else would resolve devices that see no new evidence.
  It is idempotent: in `shadow` it only enqueues the full pass again, which writes on
  change. `enter_legacy/0` is the stage-b rollback: mode `legacy`, and the shadow rows
  are dropped. `cutover` and `authoritative` belong to stage c and are refused here.
  """

  alias ServiceRadar.Inventory.Availability.ShadowEntryWorker
  alias ServiceRadar.Repo

  @type t :: :legacy | :shadow | :cutover | :authoritative

  @cache_key {__MODULE__, :mode}
  @default_cache_ms 30_000
  @modes %{
    "legacy" => :legacy,
    "shadow" => :shadow,
    "cutover" => :cutover,
    "authoritative" => :authoritative
  }

  @doc "The mode as the database has it now. Inside a transaction, as that transaction sees it."
  @spec current(keyword()) :: t()
  def current(query_opts \\ []) do
    %{rows: [[mode]]} = Repo.query!("SELECT platform.availability_mode()", [], query_opts)
    Map.fetch!(@modes, mode)
  end

  @doc """
  The mode from this node's cache. Never raises: when the database cannot be read the
  last known mode is kept, or `:legacy` when there is none, which resolves nothing.
  """
  @spec cached() :: t()
  def cached do
    now = System.monotonic_time(:millisecond)
    ttl = cache_ms()

    case :persistent_term.get(@cache_key, nil) do
      {mode, fetched_at} when now - fetched_at < ttl -> mode
      cached -> refresh(now, cached)
    end
  end

  @doc "Whether writes resolve availability: only in `shadow` for stage b."
  @spec resolving?(t()) :: boolean()
  def resolving?(mode \\ cached()), do: mode == :shadow

  @doc "Drops this node's cached mode, so the next `cached/0` reads the database."
  @spec reset_cache() :: :ok
  def reset_cache do
    :persistent_term.erase(@cache_key)
    :ok
  end

  @doc """
  Switches `legacy` to `shadow` (or repeats the entry in `shadow`) and enqueues the full
  resolution and the compatibility-table seed. Returns the mode it found.
  """
  @spec enter_shadow() :: {:ok, %{from: t(), to: :shadow}} | {:error, term()}
  def enter_shadow do
    switch(fn
      from when from in [:legacy, :shadow] ->
        # Entering from legacy starts the expiry window now; a repeat keeps it.
        Repo.query!("""
        UPDATE platform.availability_settings
        SET mode = 'shadow',
            updated_at = (now() AT TIME ZONE 'utc'),
            expiry_watermark = CASE WHEN mode = 'shadow' AND expiry_watermark IS NOT NULL
                                    THEN expiry_watermark
                                    ELSE (now() AT TIME ZONE 'utc') END
        WHERE singleton
        """)

        :ok = ShadowEntryWorker.enqueue()
        {:ok, %{from: from, to: :shadow}}

      from ->
        {:error, {:unsupported_switch, from, :shadow}}
    end)
  end

  @doc """
  The stage-b rollback: mode `legacy`, the expiry window cleared and the shadow rows
  dropped. Evidence, the per-agent ledger and the compatibility table are untouched.
  """
  @spec enter_legacy() :: {:ok, %{from: t(), to: :legacy}} | {:error, term()}
  def enter_legacy do
    switch(fn
      from when from in [:legacy, :shadow] ->
        Repo.query!("""
        UPDATE platform.availability_settings
        SET mode = 'legacy', updated_at = (now() AT TIME ZONE 'utc'), expiry_watermark = NULL
        WHERE singleton
        """)

        Repo.query!("TRUNCATE platform.device_availability_shadow")
        {:ok, %{from: from, to: :legacy}}

      from ->
        {:error, {:unsupported_switch, from, :legacy}}
    end)
  end

  defp switch(apply_switch) do
    result =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '5s'")

        Repo.query!("""
        INSERT INTO platform.availability_settings (singleton) VALUES (true)
        ON CONFLICT (singleton) DO NOTHING
        """)

        %{rows: [[mode]]} =
          Repo.query!(
            "SELECT mode FROM platform.availability_settings WHERE singleton FOR UPDATE"
          )

        case apply_switch.(Map.fetch!(@modes, mode)) do
          {:ok, switched} -> switched
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    reset_cache()
    result
  end

  defp refresh(now, cached) do
    # Inside a caller's transaction the read runs in a savepoint, so a failure cannot
    # abort the caller's write.
    mode = current(if Repo.in_transaction?(), do: [mode: :savepoint], else: [])
    :persistent_term.put(@cache_key, {mode, now})
    mode
  rescue
    _error ->
      case cached do
        {mode, _fetched_at} -> mode
        _ -> :legacy
      end
  end

  defp cache_ms do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:cache_ms, @default_cache_ms)
  end
end
