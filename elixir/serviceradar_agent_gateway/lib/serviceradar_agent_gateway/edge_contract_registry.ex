defmodule ServiceRadarAgentGateway.EdgeContractRegistry do
  @moduledoc """
  The contract registry the gateway admits edge records against, and the admission decision
  itself (enable-edge-record-pipeline-by-default, design Decisions 3, 4, 5, 7 and 12).

  ## Where the registry comes from

  Core derives the registry from its release catalog and signs every epoch with the edge issuer
  key (`ServiceRadar.Edge.ContractRegistryEpochDocument`). It sends every non-retired epoch in the
  `"contract_registry"` member of the trust document the gateway refreshes every five seconds
  (`ServiceRadar.Edge.RecordTrust`), and `ServiceRadarAgentGateway.EdgeRecordTrust` installs
  trust and registry together from that one read. `verify_member/2` is the only way a registry
  is built: it parses each epoch with the encoder core uses (`from_trust/1`) and verifies its
  signature (`verify/2`) under the issuer key the epoch names, taken from the same document's
  trust keys. One epoch that does not parse or verify refuses the whole member. There is no
  installation-static registry.

  ## Projectable bundles

  The member may carry `"projectable_bundles"`, the lowercase-hex bundle digests some live core
  node can project (Decision 4). When it is present, a record under any other bundle is
  withheld as `:bundle_not_projectable`, so the agent keeps it spooled until a node that can
  project it returns.

  Core does not publish the set yet (task 1.4, "For a bundle no live core can project"). Until
  it does, the key is optional and its absence means "no projectability restriction", which is
  what every gateway did before the set existed. Once core always sends it, make the key
  required in `verify_member/2` and delete the `nil` clause of `projectable/2`.

  ## The decision

  `admit/3` classifies one authorized record for one authenticated session:

    * `{:ok, route}` -- publish, using ONLY the route the epoch entry pins (`route_profile`,
      `traffic_class`, `partition_rule`). Nothing on the frame selects them.
    * `{:reject, reason}` -- provably unpublishable, resolved as a permanent rejection:
      provenance that disagrees with the session; a record naming no output contract; an
      installation-static epoch (`:static_registry_epoch`, below `floor/0`); a retired epoch
      (`:registry_epoch_retired`); and, under an epoch the gateway holds, a snapshot digest,
      contract or bundle digest that epoch does not sign, or a route or cost model its entry
      does not pin. An epoch's document is signed and immutable, so none of these can clear by
      waiting, and withholding them would cap the lane for good.
    * `{:withhold, reason}` -- not publishable now, but not proof of poison: no verified registry
      or one holding no epoch (`:registry_unavailable`), an epoch newer than any the gateway holds
      (`:registry_epoch_ahead`), or a bundle outside the projectable set
      (`:bundle_not_projectable`). The sequence stays unresolved.

  ## Each record is admitted against the epoch it names

  The gateway holds every non-retired epoch, and a record is admitted against the entry of the
  epoch it names, never the newest one. A draining epoch's backlog therefore drains under its
  exact bundle after a newer epoch changed that contract, until the epoch retires (Decision 5).
  Lifecycle is per epoch: a record is admitted under a `candidate`, `active` or `draining` epoch
  alike, because the gateway admits under every epoch whose signed document it has verified and
  core alone decides what it signs under.

  An epoch the gateway does not hold is either newer than everything it holds, which is lag and
  withheld, or older than the newest one it holds. Core numbers epochs upward and every document
  carries every non-retired epoch, so an older epoch missing from the document has retired, and
  its record is rejected as `:registry_epoch_retired`.

  `epoch_refusal/2` is the part of that classification that needs no capability: the static-era
  and retired rejections. `ServiceRadarAgentGateway.EdgeRecordAuthorization` runs it before it
  looks up any issuer key (Decision 7), so an unknown or rotated key id cannot turn either
  rejection into a withhold.

  ## Provenance is compared, never trusted

  The session -- the authenticated agent identity and the opened lane -- is the authority. The
  record's `origin_principal_id` must equal the authenticated component id, and its route
  profile and traffic class must equal both the lane and the bundle. Network scope is bound to
  the agent by `EdgeRecordAuthorization`, not here.
  """

  alias ServiceRadar.Edge.ContractRegistry
  alias ServiceRadar.Edge.ContractRegistryEpochDocument
  alias Serviceradar.Edge.V1.EdgeRecordV1

  @format_version 2
  @member_keys ~w(format_version epochs)
  @optional_member_keys ~w(projectable_bundles)
  # Core's report bound (`ServiceRadar.Edge.ContractRegistry`): a gateway never holds more epochs
  # than it can report.
  @max_epochs 64
  @max_projectable_bundles 1_024

  @type epoch :: map()

  @type t :: %{
          epochs: %{pos_integer() => epoch()},
          newest: pos_integer() | nil,
          projectable: MapSet.t() | nil
        }

  @type refused :: %{epoch: pos_integer(), signing_key_id: <<_::128>>, reason: atom()}

  @type session :: %{
          authenticated_agent_id: String.t(),
          route_profile: atom(),
          traffic_class: atom()
        }

  @type route :: %{route_profile: atom(), traffic_class: atom(), partition_rule: atom()}

  @type decision :: {:ok, route()} | {:reject, atom()} | {:withhold, atom()}

  @doc "The first derived epoch number; every epoch below it is installation-static."
  @spec floor() :: pos_integer()
  def floor, do: ContractRegistry.floor()

  @doc """
  Parses and verifies a trust document's `"contract_registry"` member under `public_keys`
  (issuer public keys by key id).

  `{:ok, registry}` only when every epoch parses and verifies. Otherwise
  `{:error, reason, refused}`: the member is refused whole, and `refused` names each epoch that
  could be identified, with the reason it was refused.
  """
  @spec verify_member(term(), %{optional(binary()) => <<_::256>>}) ::
          {:ok, t()} | {:error, atom(), [refused()]}
  def verify_member(%{} = member, public_keys) when is_map(public_keys) do
    with :ok <- member_shape(member),
         {:ok, projectable} <- projectable_bundles(Map.get(member, "projectable_bundles")),
         {:ok, epochs} <- parse_epochs(member["epochs"]),
         :ok <- verify_epochs(epochs, public_keys) do
      {:ok, build(epochs, projectable)}
    end
  end

  def verify_member(nil, _public_keys), do: {:error, :registry_member_missing, []}
  def verify_member(_member, _public_keys), do: {:error, :registry_member, []}

  @doc """
  Re-verifies a registry held from an earlier document under `public_keys` before it is used
  again, so a held copy is reused only while its signatures verify under the keys now trusted.
  """
  @spec reverify(t(), %{optional(binary()) => <<_::256>>}) :: {:ok, t()} | {:error, atom(), [refused()]}
  def reverify(%{epochs: epochs} = registry, public_keys) do
    with :ok <- verify_epochs(Map.values(epochs), public_keys), do: {:ok, registry}
  end

  @doc "The epochs a registry holds, by number and snapshot digest, in ascending order."
  @spec installed(t() | nil) :: [%{epoch: pos_integer(), snapshot_sha256: <<_::256>>}]
  def installed(nil), do: []

  def installed(%{epochs: epochs}) do
    epochs
    |> Map.values()
    |> Enum.sort_by(& &1.epoch)
    |> Enum.map(&%{epoch: &1.epoch, snapshot_sha256: &1.snapshot_sha256})
  end

  @doc """
  Whether `registry` holds an epoch to admit under. A verified member with no epochs replaces
  the held registry but admits nothing, so it is unavailable exactly like no registry.
  """
  @spec available?(t() | nil) :: boolean()
  def available?(%{epochs: epochs}), do: map_size(epochs) > 0
  def available?(nil), do: false

  @doc """
  The epoch rejections that need no capability: an installation-static epoch, and an epoch
  `registry` shows as retired. `:ok` means only that neither applies.
  """
  @spec epoch_refusal(struct() | nil, t() | nil) :: :ok | {:reject, atom()}
  def epoch_refusal(nil, _registry), do: {:reject, :contract_missing}

  def epoch_refusal(%{registry_epoch: epoch}, registry) do
    cond do
      epoch < floor() -> {:reject, :static_registry_epoch}
      registry != nil and retired?(epoch, registry) -> {:reject, :registry_epoch_retired}
      true -> :ok
    end
  end

  @doc """
  Classifies one authorized record for one authenticated session against `registry` (`nil`
  when no verified registry is installed). See the moduledoc for the three classes. Session
  checks run first: a frame whose provenance disagrees with its session is invalid whatever the
  registry says.
  """
  @spec admit(EdgeRecordV1.t(), session(), t() | nil) :: decision()
  def admit(%EdgeRecordV1{} = record, session, registry) do
    with :ok <- provenance(record, session),
         :ok <- epoch_refusal(record.output_contract, registry),
         {:ok, registry} <- available(registry),
         {:ok, entry} <- lookup(record.output_contract, registry),
         :ok <- pinned(record, entry),
         :ok <- projectable(entry, registry) do
      {:ok, Map.take(entry, [:route_profile, :traffic_class, :partition_rule])}
    end
  end

  # --- admission ---------------------------------------------------------------------------

  defp provenance(record, session) do
    principal = record.producer_context && record.producer_context.origin_principal_id

    cond do
      principal != session.authenticated_agent_id -> {:reject, :principal_mismatch}
      record.route_profile != session.route_profile -> {:reject, :lane_conflict}
      record.traffic_class != session.traffic_class -> {:reject, :lane_conflict}
      true -> :ok
    end
  end

  defp available(registry) do
    if available?(registry), do: {:ok, registry}, else: {:withhold, :registry_unavailable}
  end

  # Static-era and retired epochs were already rejected by `epoch_refusal/2`, so an epoch this
  # registry does not hold is newer than all of them.
  defp lookup(contract, %{epochs: epochs}) do
    case Map.fetch(epochs, contract.registry_epoch) do
      {:ok, epoch} -> entry(contract, epoch)
      :error -> {:withhold, :registry_epoch_ahead}
    end
  end

  defp entry(%{registry_snapshot_sha256: snapshot}, %{snapshot_sha256: held}) when snapshot != held,
    do: {:reject, :registry_snapshot_mismatch}

  defp entry(contract, epoch) do
    case Map.fetch(epoch.contracts, {contract.contract_id, contract.contract_version}) do
      :error -> {:reject, :unknown_contract}
      {:ok, %{contract_bundle_sha256: digest} = entry} when digest == contract.contract_bundle_sha256 -> {:ok, entry}
      {:ok, _entry} -> {:reject, :contract_digest_mismatch}
    end
  end

  # An epoch below the newest one held that the document does not carry has retired: core numbers
  # epochs upward and sends every non-retired one.
  defp retired?(epoch, %{epochs: epochs, newest: newest}) do
    case Map.fetch(epochs, epoch) do
      {:ok, %{state: state}} -> state == :retired
      :error -> newest != nil and epoch < newest
    end
  end

  # The session already equals the record's lane (provenance/2), so comparing the record here also
  # binds the lane to the bundle's pinned route.
  defp pinned(record, entry) do
    cond do
      record.route_profile != entry.route_profile -> {:reject, :route_conflict}
      record.traffic_class != entry.traffic_class -> {:reject, :route_conflict}
      record.cost_model_version != entry.cost_model_version -> {:reject, :cost_model_mismatch}
      true -> :ok
    end
  end

  defp projectable(_entry, %{projectable: nil}), do: :ok

  defp projectable(entry, %{projectable: bundles}) do
    if MapSet.member?(bundles, entry.contract_bundle_sha256),
      do: :ok,
      else: {:withhold, :bundle_not_projectable}
  end

  # --- parsing and verification ------------------------------------------------------------

  defp member_shape(member) do
    keys = Map.keys(member)

    cond do
      @member_keys -- keys != [] -> {:error, :registry_member, []}
      keys -- (@member_keys ++ @optional_member_keys) != [] -> {:error, :registry_member, []}
      member["format_version"] != @format_version -> {:error, :registry_format_version, []}
      true -> :ok
    end
  end

  defp projectable_bundles(nil), do: {:ok, nil}

  defp projectable_bundles(list) when is_list(list) and length(list) <= @max_projectable_bundles do
    digests = Enum.map(list, &decode_digest/1)
    set = MapSet.new(digests)

    if Enum.all?(digests, &is_binary/1) and MapSet.size(set) == length(list),
      do: {:ok, set},
      else: {:error, :registry_projectable_bundles, []}
  end

  defp projectable_bundles(_list), do: {:error, :registry_projectable_bundles, []}

  defp decode_digest(hex) when is_binary(hex) and byte_size(hex) == 64 do
    case Base.decode16(hex, case: :lower) do
      {:ok, digest} -> digest
      :error -> :error
    end
  end

  defp decode_digest(_hex), do: :error

  defp parse_epochs(items) when is_list(items) and length(items) <= @max_epochs do
    results = Enum.map(items, &{&1, ContractRegistryEpochDocument.from_trust(&1)})
    epochs = for {_item, {:ok, epoch}} <- results, do: epoch
    numbers = Enum.map(epochs, & &1.epoch)

    cond do
      length(epochs) != length(items) ->
        {:error, :registry_epoch_malformed, Enum.flat_map(results, &identify/1)}

      length(Enum.uniq(numbers)) != length(numbers) ->
        {:error, :registry_epoch_duplicate, []}

      true ->
        {:ok, epochs}
    end
  end

  defp parse_epochs(_items), do: {:error, :registry_epochs, []}

  # A malformed epoch is reported when its number and key id can still be read, so core's pipeline
  # status can name it.
  defp identify({%{"registry_epoch" => epoch, "signing_key_id" => key_id}, {:error, _reason}})
       when is_integer(epoch) and epoch > 0 and is_binary(key_id) do
    case Base.decode64(key_id) do
      {:ok, <<_::128>> = id} -> [%{epoch: epoch, signing_key_id: id, reason: :registry_epoch_malformed}]
      _ -> []
    end
  end

  defp identify(_result), do: []

  defp verify_epochs(epochs, public_keys) do
    refused =
      for epoch <- epochs,
          {:error, reason} <- [ContractRegistryEpochDocument.verify(epoch, public_keys)],
          do: %{epoch: epoch.epoch, signing_key_id: epoch.signing_key_id, reason: reason}

    case Enum.sort_by(refused, & &1.epoch) do
      [] -> :ok
      [%{reason: reason} | _] = sorted -> {:error, reason, sorted}
    end
  end

  defp build(epochs, projectable) do
    %{
      epochs: Map.new(epochs, &{&1.epoch, &1}),
      newest: epochs |> Enum.map(& &1.epoch) |> Enum.max(fn -> nil end),
      projectable: projectable
    }
  end
end
