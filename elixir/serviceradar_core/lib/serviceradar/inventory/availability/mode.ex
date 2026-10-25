defmodule ServiceRadar.Inventory.Availability.Mode do
  @moduledoc """
  The deployment's availability mode (`inventory.availability_mode`, design Decision 10)
  and the switches between `legacy`, `shadow`, `cutover` and `authoritative`.

  `cached/0` is the gate inline resolution checks on every write path. It reads the
  mode from this node's cache, refreshed at most every 30 seconds
  (`config :serviceradar_core, #{inspect(__MODULE__)}, cache_ms: ...`), so in `legacy` a
  sweep or evidence write issues no query for availability. Writers that pass the gate
  re-read the mode inside their own transaction (`current/1`) before resolving.

  ## Switching

  `ServiceRadar.Inventory.Availability.ProgressionWorker` makes every switch by itself,
  as the deployment's mode control (`ServiceRadar.Inventory.Availability.ModeControl`)
  says. Support can still switch through `ServiceRadar.Inventory.Availability.Operator`.
  Each switch takes `control:`, the control the caller decided from: when the stored
  control differs under the switch lock (someone changed it meanwhile), the switch
  returns `{:error, :control_changed}` and changes nothing.

  `enter_shadow/1` moves `legacy` to `shadow`, starts the expiry window, records the
  entry time (`shadow_entered_at`), and enqueues one full, paged resolution of every
  device plus the seeding of the compatibility table
  (`ServiceRadar.Inventory.Availability.ShadowEntryWorker`); the invalidation log is
  empty in `legacy`, so nothing else would resolve devices that see no new evidence.
  Entering from `legacy` first drops shadow rows left by an earlier shadow period.
  It is idempotent: in `shadow` it only enqueues the full pass again, which writes on
  change.

  `enter_cutover/1` (stage c) moves `shadow` to `cutover`. Under the drained switch it
  seeds `device_availability_legacy` from every device's `is_available`, so a device no
  legacy writer touches again keeps its legacy value, and enqueues the reconciliation
  (`ServiceRadar.Inventory.Availability.CutoverWorker`). From then on the resolver writes
  the device rows with every transition side effect suppressed, and the legacy writers
  write only the compatibility table (`ServiceRadar.Inventory.Availability.LegacyWrites`).
  The reconciliation moves the mode to `authoritative` when it has finished
  (`finish_cutover/0`); only then does the resolver emit transitions.

  `enter_legacy/1` is the rollback from any other mode: mode `legacy`, the expiry
  window and the shadow entry cleared, the shadow rows dropped and waiting entry,
  cutover and transition jobs deleted. In `legacy` it changes nothing, so a repeated
  rollback cannot delete the restore an earlier one enqueued. Coming from `cutover` or
  `authoritative` it also enqueues the restore of `is_available` from the compatibility
  table (`CutoverWorker`, phase `"restore"`), which runs after the switch has committed,
  so it never holds the switch lock while it waits on device rows.

  Other nodes keep their cached `legacy` for up to `cache_ms/0` after the switch and
  skip inline resolution meanwhile, so the full pass is scheduled to start only after
  every node's cache has expired (`ShadowEntryWorker.enqueue/0`); what a stale node
  wrote before then is resolved by that pass.

  ## The switch lock

  A switch takes one advisory lock exclusively for its transaction; every resolving
  transaction takes it shared before it reads the mode (`admit/1`). A resolver admitted
  under `shadow` therefore finishes its shadow write before a rollback's TRUNCATE can
  commit, and none is admitted mid-switch. The switch uses `pg_try_advisory_xact_lock`
  in a bounded retry loop (100 tries, 100 ms apart, then `{:error, :mode_switch_busy}`) and never the blocking form: a queued
  exclusive request would make an inline resolver that already holds device locks (a
  merge) queue behind it while an admitted resolver waits on those device locks, a
  deadlock. Holding the lock, the switch waits on no device row.
  """

  alias ServiceRadar.Inventory.Availability.CutoverWorker
  alias ServiceRadar.Inventory.Availability.ShadowEntryWorker
  alias ServiceRadar.Inventory.Availability.Transitions
  alias ServiceRadar.Repo

  @type t :: :legacy | :shadow | :cutover | :authoritative

  # The cached mode is an atom, which `:persistent_term` replaces without a global GC
  # (a tuple or any other boxed value would scan every process on each refresh); when it
  # was read lives in an `:atomics` cell created once per node.
  @mode_key {__MODULE__, :mode}
  @fetched_at_key {__MODULE__, :fetched_at}
  @default_cache_ms 30_000
  @switch_lock "hashtextextended('serviceradar:availability-mode', 0)"
  @switch_lock_tries 100
  @switch_lock_retry_ms 100
  @switch_timeout_ms 300_000
  @modes %{
    "legacy" => :legacy,
    "shadow" => :shadow,
    "cutover" => :cutover,
    "authoritative" => :authoritative
  }

  @doc """
  Admits a resolving transaction: takes the mode-switch lock shared, held until the
  transaction ends, then returns `current/1`. The caller may write shadow rows while the
  result is `:shadow`; no switch can commit before its transaction ends.
  """
  @spec admit(keyword()) :: t()
  def admit(query_opts \\ []) do
    Repo.query!("SELECT pg_advisory_xact_lock_shared(#{@switch_lock})", [], query_opts)
    current(query_opts)
  end

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

    case :persistent_term.get(@mode_key, nil) do
      nil ->
        refresh(now, nil)

      mode ->
        if now - :atomics.get(fetched_at(), 1) < cache_ms(), do: mode, else: refresh(now, mode)
    end
  end

  @doc "Whether writes resolve availability: in `shadow`, `cutover` and `authoritative`."
  @spec resolving?(t()) :: boolean()
  def resolving?(mode \\ cached()), do: mode in [:shadow, :cutover, :authoritative]

  @doc """
  Whether the legacy writers own `ocsf_devices.is_available` in `mode`: in `legacy` and
  `shadow`. From `cutover` the resolver owns it and the legacy writers write only the
  compatibility table.
  """
  @spec legacy_column?(t()) :: boolean()
  def legacy_column?(mode), do: mode in [:legacy, :shadow]

  @doc "Drops this node's cached mode, so the next `cached/0` reads the database."
  @spec reset_cache() :: :ok
  def reset_cache do
    :persistent_term.erase(@mode_key)
    :ok
  end

  @doc """
  Switches `legacy` to `shadow` (or repeats the entry in `shadow`) and enqueues the full
  resolution and the compatibility-table seed. Returns the mode it found.
  """
  @spec enter_shadow(keyword()) :: {:ok, %{from: t(), to: :shadow}} | {:error, term()}
  def enter_shadow(opts \\ []) do
    switch(opts, fn
      # A rollback whose restore has not finished would leave resolver values in
      # is_available, and the shadow entry seed would copy them into the compatibility
      # table, losing the legacy values the restore puts back.
      :legacy = from ->
        if CutoverWorker.outstanding?("restore"),
          do: {:error, :restore_pending},
          else: shadow_from(from)

      :shadow = from ->
        shadow_from(from)

      from ->
        {:error, {:unsupported_switch, from, :shadow}}
    end)
  end

  defp shadow_from(from) do
    # Rows left by an earlier shadow period are stale.
    if from == :legacy, do: Repo.query!("TRUNCATE platform.device_availability_shadow")

    # Entering from legacy starts the expiry window and the shadow period now, and
    # forgets an earlier period's full resolution; a repeat keeps all three.
    Repo.query!("""
    UPDATE platform.availability_settings
    SET mode = 'shadow',
        updated_at = (now() AT TIME ZONE 'utc'),
        expiry_watermark = CASE WHEN mode = 'shadow' AND expiry_watermark IS NOT NULL
                                THEN expiry_watermark
                                ELSE (now() AT TIME ZONE 'utc') END,
        shadow_entered_at = CASE WHEN mode = 'shadow' AND shadow_entered_at IS NOT NULL
                                 THEN shadow_entered_at
                                 ELSE (now() AT TIME ZONE 'utc') END,
        shadow_resolved_at = CASE WHEN mode = 'shadow' THEN shadow_resolved_at END
    WHERE singleton
    """)

    :ok = ShadowEntryWorker.enqueue()
    {:ok, %{from: from, to: :shadow}}
  end

  @doc """
  The rollback from any other mode: mode `legacy`, the expiry window and the shadow
  entry cleared, the shadow rows dropped and waiting entry, cutover and transition jobs
  deleted. From `cutover` or `authoritative` it also enqueues the restore of
  `is_available` from the compatibility table, which the mirror turns back into
  `availability_state`. Evidence, the per-agent ledger and the compatibility table are
  untouched. In `legacy` it changes nothing: a second rollback must not delete the
  restore the first one enqueued.
  """
  @spec enter_legacy(keyword()) :: {:ok, %{from: t(), to: :legacy}} | {:error, term()}
  def enter_legacy(opts \\ []) do
    switch(opts, fn
      :legacy -> {:ok, %{from: :legacy, to: :legacy}}
      from -> legacy_from(from)
    end)
  end

  defp legacy_from(from) do
    Repo.query!("""
    UPDATE platform.availability_settings
    SET mode = 'legacy', updated_at = (now() AT TIME ZONE 'utc'), expiry_watermark = NULL,
        shadow_entered_at = NULL, shadow_resolved_at = NULL
    WHERE singleton
    """)

    Repo.query!("TRUNCATE platform.device_availability_shadow")
    :ok = ShadowEntryWorker.cancel_waiting()
    :ok = CutoverWorker.cancel_waiting()
    :ok = Transitions.cancel_waiting()
    if from in [:cutover, :authoritative], do: :ok = CutoverWorker.enqueue("restore")
    {:ok, %{from: from, to: :legacy}}
  end

  @seed_legacy """
  INSERT INTO platform.device_availability_legacy AS legacy (device_uid, is_available, updated_at)
  SELECT uid, is_available, (now() AT TIME ZONE 'utc') FROM platform.ocsf_devices
  ON CONFLICT (device_uid) DO UPDATE
    SET is_available = EXCLUDED.is_available, updated_at = EXCLUDED.updated_at
    WHERE legacy.is_available IS DISTINCT FROM EXCLUDED.is_available
  """

  @doc """
  Switches `shadow` to `cutover` (stage c). Under the drained switch the compatibility
  table is seeded from every device's `is_available`, before any reader or writer sees
  `cutover`; then the reconciliation is enqueued. Repeating it in `cutover` only
  enqueues the reconciliation again. The expiry window that `shadow` started is kept.
  """
  @spec enter_cutover(keyword()) :: {:ok, %{from: t(), to: :cutover}} | {:error, term()}
  def enter_cutover(opts \\ []) do
    switch(opts, fn
      from when from in [:shadow, :cutover] ->
        if from == :shadow do
          Repo.query!(@seed_legacy, [], timeout: :infinity)

          Repo.query!("""
          UPDATE platform.availability_settings
          SET mode = 'cutover', updated_at = (now() AT TIME ZONE 'utc')
          WHERE singleton
          """)
        end

        :ok = CutoverWorker.enqueue("reconcile")
        {:ok, %{from: from, to: :cutover}}

      from ->
        {:error, {:unsupported_switch, from, :cutover}}
    end)
  end

  @doc """
  Moves `cutover` to `authoritative` once the reconciliation has re-resolved every
  device, and enqueues its announcement in the same transaction. Called only by
  `CutoverWorker`; any other mode is left as it is (a rollback won the race).
  """
  @spec finish_cutover() :: {:ok, %{from: t(), to: :authoritative}} | {:error, term()}
  def finish_cutover do
    switch([], fn
      :cutover ->
        Repo.query!("""
        UPDATE platform.availability_settings
        SET mode = 'authoritative', updated_at = (now() AT TIME ZONE 'utc')
        WHERE singleton
        """)

        :ok = CutoverWorker.enqueue("announce")
        {:ok, %{from: :cutover, to: :authoritative}}

      from ->
        {:error, {:unsupported_switch, from, :authoritative}}
    end)
  end

  defp switch(opts, apply_switch) do
    result =
      Repo.transaction(
        fn ->
          Repo.query!("SET LOCAL lock_timeout = '5s'")
          if not switch_locked?(@switch_lock_tries), do: Repo.rollback(:mode_switch_busy)

          Repo.query!("""
          INSERT INTO platform.availability_settings (singleton) VALUES (true)
          ON CONFLICT (singleton) DO NOTHING
          """)

          %{rows: [[mode, control]]} =
            Repo.query!(
              "SELECT mode, mode_control FROM platform.availability_settings WHERE singleton FOR UPDATE"
            )

          with :ok <- expected_control(opts, control),
               {:ok, switched} <- apply_switch.(Map.fetch!(@modes, mode)) do
            switched
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end,
        # Seeding the compatibility table writes one row per device.
        timeout: @switch_timeout_ms
      )

    reset_cache()
    result
  end

  defp expected_control(opts, stored) do
    case Keyword.fetch(opts, :control) do
      {:ok, control} ->
        if Atom.to_string(control) == stored, do: :ok, else: {:error, :control_changed}

      :error ->
        :ok
    end
  end

  defp switch_locked?(tries) do
    %{rows: [[locked?]]} = Repo.query!("SELECT pg_try_advisory_xact_lock(#{@switch_lock})")

    cond do
      locked? ->
        true

      tries <= 1 ->
        false

      true ->
        Process.sleep(@switch_lock_retry_ms)
        switch_locked?(tries - 1)
    end
  end

  defp refresh(now, cached) do
    # Inside a caller's transaction the read runs in a savepoint, so a failure cannot
    # abort the caller's write.
    mode = current(if Repo.in_transaction?(), do: [mode: :savepoint], else: [])
    :atomics.put(fetched_at(), 1, now)
    :persistent_term.put(@mode_key, mode)
    mode
  rescue
    _error -> cached || :legacy
  end

  defp fetched_at do
    case :persistent_term.get(@fetched_at_key, nil) do
      nil ->
        cell = :atomics.new(1, signed: true)
        :persistent_term.put(@fetched_at_key, cell)
        cell

      cell ->
        cell
    end
  end

  @doc "How long a node keeps its cached mode, in milliseconds."
  @spec cache_ms() :: pos_integer()
  def cache_ms do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:cache_ms, @default_cache_ms)
  end
end
