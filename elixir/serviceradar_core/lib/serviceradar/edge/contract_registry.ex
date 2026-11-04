defmodule ServiceRadar.Edge.ContractRegistry do
  @moduledoc """
  The core-derived edge-record contract registry: the signed epochs in
  `platform.edge_contract_registry_epochs` (`ServiceRadar.Edge.ContractRegistryEpoch`), and the
  one cached reader core and EventWriter read them through.

  ## Epochs

  A release's registry is a pure function of its catalog (`ServiceRadar.Edge.ContractBundle`).
  `ensure_local_epoch/1` records it: a core node whose catalog digest matches no epoch inserts
  it as the `candidate`, signed with the issuer key, under the next epoch number. Numbers start
  at `floor/0`, above every installation-static registry label. In the same transaction it
  retires any older candidate unactivated, and, when no epoch is active (every fresh install
  and every upgrade from the static registry), activates the new one at once.

  A node whose catalog matches only a `draining` or `retired` epoch, or matches only an epoch
  retired unactivated while another candidate exists, runs a superseded release. It inserts
  nothing and claims nothing; it signs under the active epoch like every other node. The one
  exception is a catalog that matches only an abandoned candidate while no candidate exists: it
  is inserted again under a new number, so a release can be redeployed after its candidate was
  abandoned.

  ## Reading

  `view/0` returns every non-retired epoch whose row verifies, and the rows that did not. Each
  row is verified on load (`ContractRegistryEpochDocument.verify/2`): a row that fails is left
  out, nothing is signed under it, and it is reported as `registry_epoch_signature_invalid`.
  When the active epoch fails, `active_epoch/0` refuses, so core issues no new capability.

  On a core node the verified view is cached for five seconds in an ETS table owned by
  `ServiceRadar.Edge.ContractRegistryNode`. Only a view this node has just loaded and verified
  is written there, and it never leaves the node's memory.
  Elsewhere (and in tests) every read loads and verifies.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.ContractBundle
  alias ServiceRadar.Edge.ContractRegistryEpoch
  alias ServiceRadar.Edge.ContractRegistryEpochDocument
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @floor 1_000_000
  @cache_table :edge_contract_registry
  @cache_ttl_ms 5_000
  @reports_topic "edge_contract_registry:gateway_reports"
  # pg_advisory_xact_lock key serializing epoch inserts across core replicas.
  @epoch_lock_key 0x5345_5245_4732_0001
  @max_epoch_rows 1_000
  @max_report_epochs 64
  @max_gateway_id_bytes 256

  @type epoch ::
          ContractRegistryEpochDocument.t()
          | %{
              state: ContractRegistryEpochDocument.state(),
              created_at: DateTime.t(),
              activated_at: DateTime.t() | nil,
              draining_since: DateTime.t() | nil,
              drain_until: DateTime.t() | nil,
              retired_at: DateTime.t() | nil,
              last_matched_at: DateTime.t()
            }

  @type invalid :: %{epoch: pos_integer(), state: atom(), reason: atom()}
  @type view :: %{epochs: [epoch()], invalid: [invalid()]}
  @type role :: :active | :candidate | :superseded

  @doc "The first derived epoch number."
  @spec floor() :: pos_integer()
  def floor, do: @floor

  @doc "The ETS table `ServiceRadar.Edge.ContractRegistryNode` owns."
  @spec cache_table() :: atom()
  def cache_table, do: @cache_table

  @doc "The PubSub topic gateway installation reports travel on."
  @spec reports_topic() :: String.t()
  def reports_topic, do: @reports_topic

  # --- reading ---------------------------------------------------------------------------

  @doc "The verified non-retired epochs, verified under the configured issuer key."
  @spec view() :: {:ok, view()} | {:error, term()}
  def view do
    case cached(:view) do
      {:ok, view} ->
        {:ok, view}

      :miss ->
        with {:ok, key} <- IssuerKey.configured(),
             {:ok, view} <- view(key) do
          cache(:view, view)
          {:ok, view}
        end
    end
  end

  @doc "Loads and verifies the non-retired epochs under `key`, bypassing the cache."
  @spec view(IssuerKey.t()) :: {:ok, view()} | {:error, term()}
  def view(%IssuerKey{} = key) do
    with {:ok, rows} <- read_rows(non_retired_query()) do
      {epochs, invalid} = verify_rows(rows, %{key.key_id => key.public_key})
      {:ok, %{epochs: epochs, invalid: invalid}}
    end
  end

  @doc """
  The active epoch, or why core signs nothing: no epoch is active yet, or the active epoch's row
  does not verify.
  """
  @spec active_epoch() :: {:ok, epoch()} | {:error, term()}
  def active_epoch do
    with {:ok, view} <- view(), do: active_epoch(view)
  end

  @doc "The active epoch of a view."
  @spec active_epoch(view()) :: {:ok, epoch()} | {:error, term()}
  def active_epoch(%{epochs: epochs, invalid: invalid}) do
    case Enum.find(epochs, &(&1.state == :active)) do
      %{} = epoch ->
        {:ok, epoch}

      nil ->
        case Enum.find(invalid, &(&1.state == :active)) do
          %{epoch: n} -> {:error, {:registry_epoch_signature_invalid, n}}
          nil -> {:error, :no_active_epoch}
        end
    end
  end

  @doc "Drops this node's cached view, so the next read loads and verifies again."
  @spec invalidate() :: :ok
  def invalidate do
    :ets.delete(@cache_table, :view)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  The trust document's `contract_registry` member: format 2 and every non-retired epoch whose
  row verifies, with its state, entries, signature and signing key id.
  """
  @spec trust_member(IssuerKey.t()) :: {:ok, map()} | {:error, term()}
  def trust_member(%IssuerKey{} = key) do
    with {:ok, view} <- view_for(key) do
      {:ok,
       %{
         "format_version" => 2,
         "epochs" => Enum.map(view.epochs, &ContractRegistryEpochDocument.to_trust/1)
       }}
    end
  end

  # The configured key's view is the cached one; any other key loads and verifies afresh.
  defp view_for(%IssuerKey{key_id: key_id} = key) do
    case IssuerKey.configured() do
      {:ok, %IssuerKey{key_id: ^key_id}} -> view()
      _ -> view(key)
    end
  end

  # --- recording this release's epoch -----------------------------------------------------

  @doc """
  Records this node's catalog as an epoch when no epoch holds it yet, and says what the node is:
  `:active` or `:candidate` when its catalog is that epoch, `:superseded` otherwise.
  """
  @spec ensure_local_epoch(DateTime.t()) ::
          {:ok, %{role: role(), epoch: pos_integer() | nil}} | {:error, term()}
  def ensure_local_epoch(now \\ DateTime.utc_now()) do
    with {:ok, key} <- IssuerKey.configured() do
      ensure_epoch(ContractBundle.local(), key, now)
    end
  end

  @doc "Records `local` (a derived registry) as an epoch signed with `key`."
  @spec ensure_epoch(ContractBundle.local(), IssuerKey.t(), DateTime.t()) ::
          {:ok, %{role: role(), epoch: pos_integer() | nil}} | {:error, term()}
  def ensure_epoch(%{snapshot_sha256: snapshot} = local, %IssuerKey{} = key, now) do
    result =
      Repo.transact(fn ->
        with {:ok, _} <- Repo.query("SELECT pg_advisory_xact_lock($1)", [@epoch_lock_key]),
             {:ok, rows} <- read_rows(all_query()) do
          rows
          |> decide(snapshot)
          |> apply_decision(rows, local, key, now)
        end
      end)

    invalidate()

    with {:ok, {role, notifications}} <- result do
      _ = Ash.Notifier.notify(notifications)
      {:ok, role}
    end
  end

  # The catalog's epoch, if any, among rows that were not retired unactivated.
  defp decide(rows, snapshot) do
    live = Enum.reject(rows, &abandoned?/1)
    candidate = Enum.find(rows, &(&1.state == :candidate))

    case Enum.find(live, &(&1.snapshot_sha256 == snapshot)) do
      %{state: state, epoch: epoch} when state in [:active, :candidate] ->
        {:matched, state, epoch}

      %{} ->
        :superseded

      nil ->
        if candidate && Enum.any?(rows, &(&1.snapshot_sha256 == snapshot)),
          do: :superseded,
          else: {:insert, candidate}
    end
  end

  defp apply_decision({:matched, state, epoch}, _rows, _local, _key, _now),
    do: {:ok, {%{role: state, epoch: epoch}, []}}

  defp apply_decision(:superseded, _rows, _local, _key, _now),
    do: {:ok, {%{role: :superseded, epoch: nil}, []}}

  defp apply_decision({:insert, older_candidate}, rows, local, key, now) do
    number = Enum.reduce(rows, @floor - 1, &max(&1.epoch, &2)) + 1
    signed = ContractRegistryEpochDocument.sign(number, Map.values(local.contracts), key)

    with {:ok, retired} <- retire_unactivated(older_candidate, now),
         {:ok, inserted, created} <- insert_candidate(signed, now),
         {:ok, epoch, activated} <- activate_first(inserted, rows, now) do
      Logger.info(
        "Edge contract registry epoch #{number} recorded as #{epoch.state}",
        registry_epoch: number,
        registry_snapshot_sha256: Base.encode16(signed.snapshot_sha256, case: :lower)
      )

      {:ok, {%{role: epoch.state, epoch: number}, retired ++ created ++ activated}}
    end
  end

  defp retire_unactivated(nil, _now), do: {:ok, []}

  defp retire_unactivated(%ContractRegistryEpoch{epoch: number} = row, now) do
    with {:ok, _row, notifications} <-
           row
           |> Ash.Changeset.for_update(:retire_unactivated, %{retired_at: now}, actor: actor())
           |> Ash.update(return_notifications?: true) do
      Logger.info("Edge contract registry candidate #{number} retired unactivated",
        registry_epoch: number
      )

      {:ok, notifications}
    end
  end

  defp insert_candidate(signed, now) do
    ContractRegistryEpoch
    |> Ash.Changeset.for_create(
      :insert_candidate,
      %{
        epoch: signed.epoch,
        snapshot_sha256: signed.snapshot_sha256,
        document: ContractRegistryEpochDocument.document(signed.contracts),
        signature: signed.signature,
        signing_key_id: signed.signing_key_id,
        created_at: now,
        last_matched_at: now
      },
      actor: actor()
    )
    |> Ash.create(return_notifications?: true)
  end

  # With no epoch active, the first candidate activates at once: there is nothing to drain.
  defp activate_first(inserted, rows, now) do
    if Enum.any?(rows, &(&1.state == :active)) do
      {:ok, inserted, []}
    else
      inserted
      |> Ash.Changeset.for_update(:activate, %{activated_at: now}, actor: actor())
      |> Ash.update(return_notifications?: true)
    end
  end

  defp abandoned?(%{state: :retired, activated_at: nil}), do: true
  defp abandoned?(_row), do: false

  # --- gateway installation reports -------------------------------------------------------

  @doc """
  Accepts a gateway's report of the registry it installed on its last refresh: the epochs it
  holds and any it refused for a bad signature. Every core node keeps the latest report per
  gateway, which is the readiness evidence for activating a candidate.
  """
  @spec record_gateway_report(term(), DateTime.t()) :: :ok | {:error, term()}
  def record_gateway_report(report, now \\ DateTime.utc_now()) do
    with {:ok, normalized} <- normalize_report(report, now) do
      Phoenix.PubSub.broadcast(
        ServiceRadar.PubSub,
        @reports_topic,
        {:edge_registry_gateway_report, normalized}
      )
    end
  end

  @doc "The latest report of each gateway this node has received."
  @spec gateway_reports() :: [map()]
  def gateway_reports do
    @cache_table
    |> :ets.match_object({{:gateway_report, :_}, :_})
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(& &1.gateway_id)
  rescue
    ArgumentError -> []
  end

  @doc "Stores a normalized gateway report in this node's table."
  @spec store_gateway_report(map()) :: :ok
  def store_gateway_report(%{gateway_id: id} = report) do
    :ets.insert(@cache_table, {{:gateway_report, id}, report})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp normalize_report(
         %{"gateway_id" => id, "installed" => installed, "refused" => refused},
         now
       )
       when is_binary(id) and id != "" and byte_size(id) <= @max_gateway_id_bytes and
              is_list(installed) and
              length(installed) <= @max_report_epochs and is_list(refused) and
              length(refused) <= @max_report_epochs do
    with {:ok, installed} <- collect(installed, &installed_epoch/1),
         {:ok, refused} <- collect(refused, &refused_epoch/1) do
      {:ok, %{gateway_id: id, installed: installed, refused: refused, received_at: now}}
    end
  end

  defp normalize_report(_report, _now), do: {:error, :invalid_gateway_report}

  defp collect(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, {:error, :invalid_gateway_report}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp installed_epoch(%{"registry_epoch" => epoch, "registry_snapshot_sha256" => hex})
       when is_integer(epoch) and epoch > 0 and is_binary(hex) do
    case Base.decode16(hex, case: :lower) do
      {:ok, <<_::256>> = snapshot} -> {:ok, %{epoch: epoch, snapshot_sha256: snapshot}}
      _ -> :error
    end
  end

  defp installed_epoch(_item), do: :error

  defp refused_epoch(%{"registry_epoch" => epoch, "signing_key_id" => key_id, "reason" => reason})
       when is_integer(epoch) and epoch > 0 and is_binary(key_id) and is_binary(reason) and
              byte_size(reason) <= 64 do
    case Base.decode64(key_id) do
      {:ok, <<_::128>> = id} -> {:ok, %{epoch: epoch, signing_key_id: id, reason: reason}}
      _ -> :error
    end
  end

  defp refused_epoch(_item), do: :error

  # --- rows -------------------------------------------------------------------------------

  defp non_retired_query do
    ContractRegistryEpoch
    |> Ash.Query.filter(state != :retired)
    |> Ash.Query.sort(epoch: :asc)
    |> Ash.Query.limit(@max_epoch_rows + 1)
  end

  defp all_query do
    ContractRegistryEpoch
    |> Ash.Query.sort(epoch: :asc)
    |> Ash.Query.limit(@max_epoch_rows + 1)
  end

  # A deployment accrues one epoch per contract-changing release, so the table stays small; a
  # read past the cap fails closed instead of silently leaving epochs out.
  defp read_rows(query) do
    case Ash.read(query, actor: actor()) do
      {:ok, rows} when length(rows) > @max_epoch_rows -> {:error, :registry_epochs_too_many}
      {:ok, rows} -> {:ok, rows}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_rows(rows, public_keys) do
    {epochs, invalid} =
      Enum.reduce(rows, {[], []}, fn row, {ok, bad} ->
        case verify_row(row, public_keys) do
          {:ok, epoch} ->
            {[epoch | ok], bad}

          {:error, reason} ->
            Logger.error(
              "Edge contract registry epoch #{row.epoch} refused: #{reason}",
              registry_epoch: row.epoch,
              signing_key_id: Base.encode64(row.signing_key_id),
              reason: reason
            )

            {ok, [%{epoch: row.epoch, state: row.state, reason: reason} | bad]}
        end
      end)

    {Enum.reverse(epochs), Enum.reverse(invalid)}
  end

  defp verify_row(row, public_keys) do
    with {:ok, contracts} <- ContractRegistryEpochDocument.contracts(row.document),
         epoch = %{
           epoch: row.epoch,
           snapshot_sha256: row.snapshot_sha256,
           contracts: contracts,
           signature: row.signature,
           signing_key_id: row.signing_key_id
         },
         :ok <- ContractRegistryEpochDocument.verify(epoch, public_keys) do
      {:ok,
       Map.merge(epoch, %{
         state: row.state,
         created_at: row.created_at,
         activated_at: row.activated_at,
         draining_since: row.draining_since,
         drain_until: row.drain_until,
         retired_at: row.retired_at,
         last_matched_at: row.last_matched_at
       })}
    else
      {:error, :registry_epoch_signing_key_unknown} -> {:error, :registry_epoch_signature_invalid}
      {:error, :registry_epoch_signature_invalid} -> {:error, :registry_epoch_signature_invalid}
      {:error, _document_reason} -> {:error, :registry_epoch_document_invalid}
    end
  end

  # --- cache ------------------------------------------------------------------------------

  defp cached(key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@cache_table, key) do
      [{^key, value, loaded_at}] when now - loaded_at < @cache_ttl_ms -> {:ok, value}
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp cache(key, value) do
    :ets.insert(@cache_table, {key, value, System.monotonic_time(:millisecond)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp actor, do: SystemActor.system(:edge_contract_registry)
end
