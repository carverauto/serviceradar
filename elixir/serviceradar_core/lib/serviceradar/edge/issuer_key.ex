defmodule ServiceRadar.Edge.IssuerKey do
  @moduledoc """
  Core's edge-record issuer key: the Ed25519 key that signs the production capabilities and
  source authorizations of sweep schedule leases, standing output grants, and the delivery
  grants of a spool backlog.

  The private half is a 32-byte seed stored in CNPG (`ServiceRadar.Edge.EdgeIssuerKeyRecord`),
  encrypted by AshCloak. It is ServiceRadar talking to itself, not a device or integration
  credential. The gateway receives only `trust_entry/1`: the issuer id, the key id and the
  public key.

  The first boot that finds no stored key stores one. An installation upgrading from the
  file-based key (`SERVICERADAR_EDGE_ISSUER_KEY_FILE`, which the runtime config passes as
  `:edge_issuer_key_import_file`) imports that seed, so the key, and every registry epoch,
  grant and lease signed with it, survives the upgrade. Every other installation generates
  a seed. Once a key is stored, the file is never read again.

  The issuer id is fixed (`"serviceradar-core"`). The key id is the first 16 bytes of
  SHA-256 over a domain tag and the public key, so a rotated seed gets a new key id and a
  verifier can hold the old and new keys side by side.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.CallbackGrants.RuntimeConfig
  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.EdgeIssuerKeyRecord
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1

  require Logger

  @derive {Inspect, except: [:seed]}
  @enforce_keys [:issuer_id, :key_id, :public_key, :seed]
  defstruct [:issuer_id, :key_id, :public_key, :seed]

  @type t :: %__MODULE__{
          issuer_id: binary(),
          key_id: <<_::128>>,
          public_key: <<_::256>>,
          seed: <<_::256>>
        }

  @issuer_id "serviceradar-core"
  @key_id_domain "serviceradar.edge.issuer_key.v1"
  @cache_key {__MODULE__, :key}
  @max_key_file_bytes 128

  @doc "The key made from a 32-byte Ed25519 seed."
  @spec from_seed(<<_::256>>) :: t()
  def from_seed(<<_::256>> = seed) do
    {public_key, _private} = :crypto.generate_key(:eddsa, :ed25519, seed)

    %__MODULE__{
      issuer_id: @issuer_id,
      key_id: key_id(public_key),
      public_key: public_key,
      seed: seed
    }
  end

  @doc """
  The installation's issuer key, cached on the node after the first `ensure_stored/0`: the
  key never changes once stored. Nothing is cached on an error, so the next call retries.
  """
  @spec configured() :: {:ok, t()} | {:error, term()}
  def configured do
    case :persistent_term.get(@cache_key, nil) do
      %__MODULE__{} = key ->
        {:ok, key}

      nil ->
        with {:ok, key} <- ensure_stored() do
          :persistent_term.put(@cache_key, key)
          {:ok, key}
        end
    end
  end

  @doc """
  Reads the stored issuer key, storing one when none exists: the seed of the file-based key
  being upgraded from, else a generated one. The store is insert-only: when replicas race,
  one insert wins the singleton row and every replica reads that winner back, so all of them
  sign with one key. An error means the database could not be read or written, the stored
  row does not hold a valid key, or the file to import is not a private, well-formed seed
  (core then stores nothing rather than a key that would orphan the file key's signatures).
  """
  @spec ensure_stored() :: {:ok, t()} | {:error, term()}
  def ensure_stored do
    with {:ok, nil} <- read_stored(),
         {:ok, seed, source} <- seed_to_store() do
      inserted = insert_seed(seed)

      case {read_stored(), inserted} do
        {{:ok, nil}, {:error, reason}} -> {:error, reason}
        {{:ok, nil}, _inserted} -> {:error, :edge_issuer_key_not_stored}
        {{:ok, key}, {:ok, record}} -> {:ok, log_stored(key, record, source)}
        {result, _inserted} -> result
      end
    end
  end

  defp seed_to_store do
    case Application.get_env(:serviceradar_core, :edge_issuer_key_import_file) do
      path when is_binary(path) and path != "" -> import_seed(path)
      _ -> {:ok, :crypto.strong_rand_bytes(32), :generated}
    end
  end

  defp import_seed(path) do
    with {:ok, bytes} <- RuntimeConfig.read_secure_file(path, @max_key_file_bytes),
         true <- String.valid?(bytes),
         {:ok, <<_::256>> = seed} <- Base.decode64(String.trim(bytes)) do
      {:ok, seed, :imported}
    else
      _ -> {:error, :invalid_edge_issuer_key_file}
    end
  end

  defp log_stored(key, record, source) do
    if Ash.Resource.get_metadata(record, :upsert_action) == :insert do
      Logger.info(
        "Stored the edge issuer key in CNPG (#{source}); key id #{Base.encode16(key.key_id, case: :lower)}",
        edge_issuer_key_source: source
      )
    end

    key
  end

  defp read_stored do
    case Ash.read_one(EdgeIssuerKeyRecord, load: [:seed], actor: actor()) do
      {:ok, nil} -> {:ok, nil}
      {:ok, record} -> from_record(record)
      {:error, reason} -> {:error, reason}
    end
  end

  defp from_record(%EdgeIssuerKeyRecord{public_key: public_key, seed: seed}) do
    with {:ok, <<_::256>> = seed} <- decode(seed),
         {:ok, <<_::256>> = public_key} <- decode(public_key),
         %__MODULE__{public_key: ^public_key} = key <- from_seed(seed) do
      {:ok, key}
    else
      _ -> {:error, :invalid_edge_issuer_key}
    end
  end

  defp decode(value) when is_binary(value), do: Base.decode64(value)
  defp decode(_value), do: :error

  defp insert_seed(seed) do
    key = from_seed(seed)

    EdgeIssuerKeyRecord
    |> Ash.Changeset.for_create(
      :generate,
      %{public_key: Base.encode64(key.public_key), seed: Base.encode64(key.seed)},
      actor: actor()
    )
    |> Ash.create()
  end

  defp actor, do: SystemActor.system(:edge_issuer_key)

  @doc """
  Signs a capability whose claims and window are set: fills the version, issuer, key id and
  algorithm, then signs the canonical signing bytes (`CapabilitySigning.signing_bytes/1`).
  """
  @spec sign(EdgeSignedCapabilityV1.t(), t()) :: EdgeSignedCapabilityV1.t()
  def sign(%EdgeSignedCapabilityV1{} = capability, %__MODULE__{} = key) do
    unsigned = %{
      capability
      | capability_version: 1,
        issuer_id: key.issuer_id,
        issuer_key_id: key.key_id,
        algorithm: "ed25519",
        signature: ""
    }

    signature =
      :crypto.sign(:eddsa, :none, CapabilitySigning.signing_bytes(unsigned), [key.seed, :ed25519])

    %{unsigned | signature: signature}
  end

  @doc """
  The Ed25519 signature of a canonical preimage that is not a capability, such as a contract
  registry epoch (`ServiceRadar.Edge.ContractRegistryEpochDocument`). The caller owns the
  preimage's domain separation; this only signs the bytes.
  """
  @spec sign_detached(binary(), t()) :: <<_::512>>
  def sign_detached(preimage, %__MODULE__{} = key) when is_binary(preimage) do
    :crypto.sign(:eddsa, :none, preimage, [key.seed, :ed25519])
  end

  @doc """
  The gateway trust-file entry for this key: base64 ids and public key, valid for the
  production, source and delivery purposes (`ServiceRadar.Edge.DeliveryGrants` signs delivery
  grants with it). It carries no private material.
  """
  @spec trust_entry(t()) :: map()
  def trust_entry(%__MODULE__{} = key) do
    %{
      "issuer_id" => Base.encode64(key.issuer_id),
      "issuer_key_id" => Base.encode64(key.key_id),
      "public_key" => Base.encode64(key.public_key),
      "purposes" => ["production", "source", "delivery"],
      "status" => "valid"
    }
  end

  defp key_id(public_key) do
    <<id::binary-size(16), _::binary>> = :crypto.hash(:sha256, [@key_id_domain, public_key])
    id
  end
end
