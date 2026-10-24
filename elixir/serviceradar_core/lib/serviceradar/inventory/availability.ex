defmodule ServiceRadar.Inventory.Availability do
  @moduledoc """
  The single entry point for non-probe device availability evidence
  (`add-merged-device-availability`, design Decision 1).

  Controllers, hypervisors, camera managers, agent liveness, passive sightings, plugins,
  inventory records and composite-check policy submit observations through
  `record_evidence/2`. Agent reachability probes are not evidence here: they stay in the
  per-agent ledger (`device_agent_availability`).

  ## Capture

  Evidence is recorded alongside the legacy writes. Those writes own
  `ocsf_devices.is_available` in `legacy` and `shadow`; from `cutover` the resolver owns
  the column and the legacy writers record only the compatibility table
  (`ServiceRadar.Inventory.Availability.LegacyWrites`). Writers call `capture/2`, which
  never fails the write it accompanies: it is skipped when capture is switched off,
  isolates its statements in a savepoint inside a caller's transaction, and logs instead
  of raising.

  ## Resolution

  Outside `legacy`, `record_evidence/2` resolves the devices whose evidence it wrote in
  the same transaction (`resolve_devices/1`), so generic evidence never waits for the
  invalidation log. In `shadow` the decision goes only to `device_availability_shadow`;
  in `cutover` and `authoritative` it is the device's `availability_state` (see
  `ServiceRadar.Inventory.Availability.Resolution`). In `legacy` the mode check is a
  cached read and nothing else runs.

  Capture is on by default. Set `config :serviceradar_core, #{inspect(__MODULE__)},
  evidence_capture: false` (`SERVICERADAR_AVAILABILITY_EVIDENCE_CAPTURE=false`) to turn
  it off; the recorded evidence can then be truncated.
  """

  import Ecto.Query

  alias ServiceRadar.Inventory.Availability.DeviceEvidence
  alias ServiceRadar.Inventory.Availability.EvidencePlan
  alias ServiceRadar.Inventory.Availability.Mode
  alias ServiceRadar.Inventory.Availability.Resolution
  alias ServiceRadar.Inventory.Availability.Sources
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Repo

  require Logger

  @type submission :: %{
          required(:device_uid) => String.t(),
          required(:source_kind) => String.t(),
          required(:state) => :up | :down,
          required(:observed_at) => DateTime.t(),
          optional(:source_instance) => String.t() | nil,
          optional(:reporter_agent_id) => String.t() | nil,
          optional(:ttl_seconds) => pos_integer() | nil,
          optional(:instance_class) => atom() | String.t() | nil,
          optional(:reporter_eligible) => boolean(),
          optional(:detail) => map()
        }

  @type result :: %{written: non_neg_integer(), skipped: non_neg_integer(), rejected: map()}

  @doc """
  Records availability evidence, writing a record only when it changes a decision or its
  lease is due (`EvidencePlan.merge/3`).

  Each submission's class comes from its source kind's registration (`Sources`); a
  submission for an unregistered kind, or one its registration rejects, is counted in
  `rejected` by reason and not written. Evidence for a device that does not exist is
  skipped. Rows are written in key order, so concurrent writers lock in one order.

  Planning and writing run in one transaction that locks the existing rows, so
  concurrent submissions for one key are serialized. Outside `legacy` the devices' rows
  are locked first, in uid order, and the devices whose evidence was written are
  resolved before the transaction ends.

  Options: `:now` (defaults to the current time).
  """
  @spec record_evidence([submission()], keyword()) :: {:ok, result()}
  def record_evidence(submissions, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    query_opts = query_opts()

    {rows, rejected} = build_rows(submissions, now, query_opts)
    rows = live_rows(rows, query_opts)

    written =
      if Repo.in_transaction?() do
        plan_and_write(rows, now, query_opts)
      else
        {:ok, written} = Repo.transaction(fn -> plan_and_write(rows, now, query_opts) end)
        written
      end

    {:ok, %{written: written, skipped: length(rows) - written, rejected: rejected}}
  end

  defp plan_and_write(rows, now, query_opts) do
    resolving? = Mode.resolving?()

    # Device rows before evidence rows, the order a merge (which moves evidence while
    # holding both devices) and every resolution lock in. Under the lock, a device a merge
    # tombstoned meanwhile is dropped, so its evidence is not written after the move.
    rows =
      if resolving? do
        live = Resolution.lock_devices(Enum.map(rows, & &1.device_uid), query_opts)
        Enum.filter(rows, &MapSet.member?(live, &1.device_uid))
      else
        rows
      end

    existing = load_existing(rows, query_opts)

    planned =
      rows
      |> Enum.flat_map(fn row ->
        case EvidencePlan.merge(Map.get(existing, key(row)), row, now) do
          {:write, merged} -> [merged]
          :skip -> []
        end
      end)
      |> Enum.sort_by(&key/1)

    written = write(planned, query_opts)
    if resolving?, do: Resolution.resolve_devices(Enum.map(planned, & &1.device_uid))
    written
  end

  @doc """
  Resolves `device_uids` inline for a write path, under the device locks in the caller's
  transaction (or its own), writing on change: the shadow table in `shadow`, the device
  row from `cutover`. A no-op in `legacy`. Never fails the caller; see `Resolution.resolve_devices/1`.
  """
  @spec resolve_devices([String.t()]) :: {:ok, Resolution.result() | :legacy} | {:error, term()}
  defdelegate resolve_devices(device_uids), to: Resolution

  @move_evidence """
  WITH moved AS (
    DELETE FROM platform.device_availability_evidence
    WHERE device_uid = $1
    RETURNING *
  )
  INSERT INTO platform.device_availability_evidence AS e
    (device_uid, source_kind, source_instance, reporter_agent_id, authority_class, state,
     observed_at, expires_at, state_since, confirmations, reporter_eligible, detail, updated_at)
  SELECT $2, source_kind, source_instance, reporter_agent_id, authority_class, state,
         observed_at, expires_at, state_since, confirmations, reporter_eligible, detail,
         (now() AT TIME ZONE 'utc')
  FROM moved
  ON CONFLICT (device_uid, source_kind, source_instance, reporter_agent_id) DO UPDATE
    SET authority_class = EXCLUDED.authority_class,
        state = EXCLUDED.state,
        observed_at = EXCLUDED.observed_at,
        expires_at = EXCLUDED.expires_at,
        state_since = EXCLUDED.state_since,
        confirmations = EXCLUDED.confirmations,
        reporter_eligible = EXCLUDED.reporter_eligible,
        detail = EXCLUDED.detail,
        updated_at = EXCLUDED.updated_at
    WHERE EXCLUDED.observed_at > e.observed_at
  """

  @doc """
  Moves a merged-away device's evidence to the survivor (design Decision 11). On a key
  both devices hold, the later observation wins. Runs in the merge transaction, which
  already holds both device rows, so it locks only evidence rows of those devices.
  """
  @spec move_evidence(String.t(), String.t()) :: :ok | {:error, term()}
  def move_evidence(from_uid, to_uid) do
    case Repo.query(@move_evidence, [from_uid, to_uid]) do
      {:ok, _result} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  Records evidence on behalf of a legacy writer without ever failing it.

  Returns `:ok` whatever happens. Inside a caller's transaction every statement runs in
  a savepoint, so a failed capture cannot abort the caller's write.
  """
  @spec capture([submission()], keyword()) :: :ok
  def capture(submissions, opts \\ [])
  def capture([], _opts), do: :ok

  def capture(submissions, opts) do
    if capture_enabled?() do
      {:ok, result} = record_evidence(submissions, opts)

      :telemetry.execute(
        [:serviceradar, :availability, :evidence, :capture],
        %{
          submitted: length(submissions),
          written: result.written,
          skipped: result.skipped,
          rejected: result.rejected |> Map.values() |> Enum.sum()
        },
        %{source_kinds: submissions |> Enum.map(& &1.source_kind) |> Enum.uniq()}
      )
    end

    :ok
  rescue
    error ->
      Logger.warning("availability evidence capture failed: #{Exception.message(error)}")
      :ok
  end

  @doc "Whether writers record evidence. On unless switched off in config."
  @spec capture_enabled?() :: boolean()
  def capture_enabled? do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:evidence_capture, true)
  end

  defp build_rows(submissions, now, query_opts) do
    registrations =
      submissions
      |> Enum.map(&Map.get(&1, :source_kind))
      |> Enum.uniq()
      |> Map.new(&{&1, fetch_source(&1, query_opts)})

    {rows, rejected} =
      Enum.reduce(submissions, {[], %{}}, fn submission, {rows, rejected} ->
        with {:ok, source} <- Map.fetch!(registrations, Map.get(submission, :source_kind)),
             {:ok, row} <- EvidencePlan.build(submission, source, now) do
          {[row | rows], rejected}
        else
          {:error, reason} -> {rows, Map.update(rejected, reason, 1, &(&1 + 1))}
        end
      end)

    # One write per key: a batch that observed a key twice keeps the latest observation.
    rows =
      rows
      |> Enum.group_by(&key/1)
      |> Enum.map(fn {_key, observed} -> Enum.max_by(observed, & &1.observed_at, DateTime) end)

    {rows, rejected}
  end

  defp fetch_source(kind, query_opts) when is_binary(kind) do
    case Sources.fetch(kind, query_opts) do
      {:ok, source} -> {:ok, source}
      :error -> {:error, :unregistered_source}
    end
  end

  defp fetch_source(_kind, _query_opts), do: {:error, :unregistered_source}

  defp live_rows([], _query_opts), do: []

  defp live_rows(rows, query_opts) do
    uids = rows |> Enum.map(& &1.device_uid) |> Enum.uniq()

    live =
      Device
      |> where([d], d.uid in ^uids)
      |> select([d], d.uid)
      |> Repo.all(query_opts)
      |> MapSet.new()

    Enum.filter(rows, &MapSet.member?(live, &1.device_uid))
  end

  defp load_existing([], _query_opts), do: %{}

  defp load_existing(rows, query_opts) do
    uids = rows |> Enum.map(& &1.device_uid) |> Enum.uniq()
    kinds = rows |> Enum.map(& &1.source_kind) |> Enum.uniq()

    DeviceEvidence
    |> where([e], e.device_uid in ^uids and e.source_kind in ^kinds)
    |> order_by([e], [e.device_uid, e.source_kind, e.source_instance, e.reporter_agent_id])
    |> lock("FOR UPDATE")
    |> Repo.all(query_opts)
    |> Map.new(&{key(&1), &1})
  end

  defp write([], _query_opts), do: 0

  defp write(rows, query_opts) do
    on_conflict =
      from(e in DeviceEvidence,
        where: fragment("EXCLUDED.observed_at >= ?", e.observed_at),
        update: [
          set: [
            authority_class: fragment("EXCLUDED.authority_class"),
            state: fragment("EXCLUDED.state"),
            observed_at: fragment("EXCLUDED.observed_at"),
            expires_at: fragment("EXCLUDED.expires_at"),
            state_since: fragment("EXCLUDED.state_since"),
            confirmations: fragment("EXCLUDED.confirmations"),
            reporter_eligible: fragment("EXCLUDED.reporter_eligible"),
            detail: fragment("EXCLUDED.detail"),
            updated_at: fragment("EXCLUDED.updated_at")
          ]
        ]
      )

    records = Enum.map(rows, &Map.put(&1, :updated_at, statement_now()))

    {count, _} =
      Repo.insert_all(
        DeviceEvidence,
        records,
        [
          on_conflict: on_conflict,
          conflict_target: [:device_uid, :source_kind, :source_instance, :reporter_agent_id]
        ] ++ query_opts
      )

    count
  end

  # The database clock at the writing statement, as for the per-agent ledger.
  defp statement_now do
    from(n in fragment("SELECT (now() AT TIME ZONE 'utc') AS ts"), select: n.ts)
  end

  defp query_opts do
    if Repo.in_transaction?(), do: [mode: :savepoint], else: []
  end

  defp key(row), do: {row.device_uid, row.source_kind, row.source_instance, row.reporter_agent_id}
end
