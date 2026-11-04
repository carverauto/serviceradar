defmodule ServiceRadar.Edge.ContractRegistryEpochDocument do
  @moduledoc """
  The signed document of one contract registry epoch: its entry list, its snapshot digest, and
  the issuer key's signature over `ContractRegistryGrammar.registry_epoch_signing_bytes/1`.

  Core signs an epoch once, when it inserts the candidate row
  (`ServiceRadar.Edge.ContractRegistry`). Every copy read from outside the memory of the process
  that verified it is verified again before use: core's reader verifies each CNPG row, and the
  gateway verifies each epoch of the trust document's `contract_registry` member. Both sides use
  `verify/2` here, so they cannot disagree about what was signed.

  The signature covers contents, not the lifecycle: an epoch's state (`candidate`, `active`,
  `draining`, `retired`) changes after signing and comes only from core.

  Two encodings:

    * the stored document (`document/1`, `contracts/1`): `%{"contracts" => [entry]}`, entries
      sorted by `(contract_id, contract_version)`;
    * the trust-document epoch (`to_trust/1`, `from_trust/1`): the stored entries plus the epoch
      number, state, snapshot digest, signature and signing key id.

  An entry is `contract_id`, `contract_version`, `contract_bundle_sha256` (lowercase hex),
  `route_profile`, `traffic_class`, `partition_rule`, `cost_model_version` and
  `projection_revision`. Parsing is strict and fails closed: an unknown or missing key, a
  duplicate `(contract_id, contract_version)`, or a route or partition rule this installation
  cannot resolve rejects the whole document.
  """

  alias ServiceRadar.Edge.ContractBundle
  alias ServiceRadar.Edge.ContractCatalog
  alias ServiceRadar.Edge.ContractRegistryGrammar
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.StreamRoute

  @type entry :: ContractRegistryGrammar.epoch_entry()
  @type state :: :candidate | :active | :draining | :retired

  @type t :: %{
          epoch: pos_integer(),
          snapshot_sha256: <<_::256>>,
          contracts: %{ContractCatalog.ref() => entry()},
          signature: <<_::512>>,
          signing_key_id: <<_::128>>
        }

  @entry_keys ~w(contract_id contract_version contract_bundle_sha256 route_profile traffic_class
                 partition_rule cost_model_version projection_revision)
  @trust_keys ~w(registry_epoch state registry_snapshot_sha256 contracts signature signing_key_id)
  @states %{
    "candidate" => :candidate,
    "active" => :active,
    "draining" => :draining,
    "retired" => :retired
  }
  @max_contracts 256
  @max_contract_id_bytes 256
  @max_u32 0xFFFFFFFF
  @max_u64 0xFFFFFFFFFFFFFFFF

  @doc """
  Signs epoch `epoch` over `entries` with the issuer key: the snapshot digest is derived from
  the entries, so a caller cannot sign a digest that disagrees with them.
  """
  @spec sign(pos_integer(), [entry()], IssuerKey.t()) :: t()
  def sign(epoch, entries, %IssuerKey{} = key) when is_integer(epoch) and is_list(entries) do
    snapshot = ContractBundle.snapshot_sha256(entries)

    preimage =
      ContractRegistryGrammar.registry_epoch_signing_bytes(%{
        epoch: epoch,
        snapshot_sha256: snapshot,
        contracts: entries
      })

    %{
      epoch: epoch,
      snapshot_sha256: snapshot,
      contracts: Map.new(entries, &{{&1.contract_id, &1.contract_version}, &1}),
      signature: IssuerKey.sign_detached(preimage, key),
      signing_key_id: key.key_id
    }
  end

  @doc """
  Verifies a parsed epoch against the issuer public keys, keyed by key id. The snapshot digest
  must be the one its entries derive, and the signature must verify under the key the epoch
  names.
  """
  @spec verify(t(), %{optional(binary()) => <<_::256>>}) ::
          :ok | {:error, :registry_epoch_signature_invalid | :registry_epoch_signing_key_unknown}
  def verify(%{signing_key_id: key_id} = epoch, public_keys) when is_map(public_keys) do
    entries = Map.values(epoch.contracts)

    preimage =
      ContractRegistryGrammar.registry_epoch_signing_bytes(%{
        epoch: epoch.epoch,
        snapshot_sha256: epoch.snapshot_sha256,
        contracts: entries
      })

    case Map.fetch(public_keys, key_id) do
      {:ok, <<_::256>> = public_key} ->
        if ContractBundle.snapshot_sha256(entries) == epoch.snapshot_sha256 and
             :crypto.verify(:eddsa, :none, preimage, epoch.signature, [public_key, :ed25519]) do
          :ok
        else
          {:error, :registry_epoch_signature_invalid}
        end

      _ ->
        {:error, :registry_epoch_signing_key_unknown}
    end
  end

  @doc "The stored document of a set of entries."
  @spec document([entry()] | %{optional(ContractCatalog.ref()) => entry()}) :: map()
  def document(%{} = contracts), do: document(Map.values(contracts))

  def document(entries) when is_list(entries) do
    %{
      "contracts" =>
        entries
        |> Enum.sort_by(&{&1.contract_id, &1.contract_version})
        |> Enum.map(&encode_entry/1)
    }
  end

  @doc "The entries of a stored document."
  @spec contracts(term()) :: {:ok, %{ContractCatalog.ref() => entry()}} | {:error, term()}
  def contracts(%{"contracts" => list} = doc) when map_size(doc) == 1, do: entries(list)
  def contracts(_doc), do: {:error, :document}

  @doc "An epoch, with its lifecycle state, as the trust document carries it to gateways."
  @spec to_trust(t() | map()) :: map()
  def to_trust(%{state: state} = epoch) do
    %{
      "registry_epoch" => epoch.epoch,
      "state" => Atom.to_string(state),
      "registry_snapshot_sha256" => Base.encode16(epoch.snapshot_sha256, case: :lower),
      "contracts" => document(epoch.contracts)["contracts"],
      "signature" => Base.encode64(epoch.signature),
      "signing_key_id" => Base.encode64(epoch.signing_key_id)
    }
  end

  @doc """
  Parses one trust-document epoch. The result still has to pass `verify/2` before anything
  admits records under it.
  """
  @spec from_trust(term()) :: {:ok, t() | map()} | {:error, term()}
  def from_trust(%{} = item) do
    with :ok <- exact_keys(item, @trust_keys),
         {:ok, epoch} <- integer(item["registry_epoch"], @max_u64),
         {:ok, state} <- lookup(@states, item["state"], :state),
         {:ok, snapshot} <- digest(item["registry_snapshot_sha256"]),
         {:ok, contracts} <- entries(item["contracts"]),
         {:ok, signature} <- base64(item["signature"], 64),
         {:ok, key_id} <- base64(item["signing_key_id"], 16) do
      {:ok,
       %{
         epoch: epoch,
         state: state,
         snapshot_sha256: snapshot,
         contracts: contracts,
         signature: signature,
         signing_key_id: key_id
       }}
    end
  end

  def from_trust(_item), do: {:error, :epoch}

  defp encode_entry(e) do
    %{
      "contract_id" => e.contract_id,
      "contract_version" => e.contract_version,
      "contract_bundle_sha256" => Base.encode16(e.contract_bundle_sha256, case: :lower),
      "route_profile" => Atom.to_string(e.route_profile),
      "traffic_class" => Atom.to_string(e.traffic_class),
      "partition_rule" => Atom.to_string(e.partition_rule),
      "cost_model_version" => e.cost_model_version,
      "projection_revision" => e.projection_revision
    }
  end

  defp entries(list) when is_list(list) and length(list) <= @max_contracts do
    Enum.reduce_while(list, {:ok, %{}}, fn item, {:ok, acc} ->
      with {:ok, entry} <- entry(item),
           key = {entry.contract_id, entry.contract_version},
           false <- Map.has_key?(acc, key) do
        {:cont, {:ok, Map.put(acc, key, entry)}}
      else
        true -> {:halt, {:error, :duplicate_contract}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp entries(_list), do: {:error, :contracts}

  defp entry(%{} = item) do
    with :ok <- exact_keys(item, @entry_keys),
         {:ok, id} <- contract_id(item["contract_id"]),
         {:ok, version} <- integer(item["contract_version"], @max_u32),
         {:ok, bundle} <- digest(item["contract_bundle_sha256"]),
         {:ok, {profile, class}} <- lane(item["route_profile"], item["traffic_class"]),
         {:ok, rule} <- partition_rule(item["partition_rule"]),
         {:ok, cost} <- integer(item["cost_model_version"], @max_u32),
         {:ok, revision} <- integer(item["projection_revision"], @max_u64) do
      {:ok,
       %{
         contract_id: id,
         contract_version: version,
         contract_bundle_sha256: bundle,
         route_profile: profile,
         traffic_class: class,
         partition_rule: rule,
         cost_model_version: cost,
         projection_revision: revision
       }}
    end
  end

  defp entry(_item), do: {:error, :contract}

  defp exact_keys(map, keys) do
    if Enum.sort(Map.keys(map)) == Enum.sort(keys), do: :ok, else: {:error, :keys}
  end

  defp contract_id(id)
       when is_binary(id) and id != "" and byte_size(id) <= @max_contract_id_bytes, do: {:ok, id}

  defp contract_id(_id), do: {:error, :contract_id}

  defp integer(value, max) when is_integer(value) and value >= 1 and value <= max,
    do: {:ok, value}

  defp integer(_value, _max), do: {:error, :integer}

  defp digest(hex) when is_binary(hex) and byte_size(hex) == 64 do
    case Base.decode16(hex, case: :lower) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :digest}
    end
  end

  defp digest(_hex), do: {:error, :digest}

  defp base64(value, size) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, bytes} when byte_size(bytes) == size -> {:ok, bytes}
      _ -> {:error, :encoding}
    end
  end

  defp base64(_value, _size), do: {:error, :encoding}

  defp lookup(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, reason}
    end
  end

  defp lane(profile, class) do
    case Enum.find(StreamRoute.active_lanes(), fn {p, c} ->
           Atom.to_string(p) == profile and Atom.to_string(c) == class
         end) do
      nil -> {:error, :route}
      pair -> {:ok, pair}
    end
  end

  defp partition_rule(rule) do
    case Enum.find(StreamRoute.partition_rules(), &(Atom.to_string(&1) == rule)) do
      nil -> {:error, :partition_rule}
      found -> {:ok, found}
    end
  end
end
