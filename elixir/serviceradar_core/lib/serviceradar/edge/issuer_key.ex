defmodule ServiceRadar.Edge.IssuerKey do
  @moduledoc """
  Core's edge-record issuer key: the Ed25519 key that signs the production capabilities and
  source authorizations of sweep schedule leases.

  The private half is a 32-byte seed, stored base64-encoded in a file only core can read and
  named by `SERVICERADAR_EDGE_ISSUER_KEY_FILE`. It is ServiceRadar talking to itself, not a
  device or integration credential. The gateway receives only `trust_entry/1`: the issuer id,
  the key id and the public key.

  The issuer id is fixed (`"serviceradar-core"`). The key id is the first 16 bytes of
  SHA-256 over a domain tag and the public key, so rotating the seed rotates the key id and a
  verifier can hold the old and new keys side by side.
  """

  alias ServiceRadar.Automation.CallbackGrants.RuntimeConfig
  alias ServiceRadar.Edge.CapabilitySigning
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1

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
  Loads the key from a secure file holding the base64 seed. Raises on a missing, loose,
  oversized or malformed file, so a misconfigured issuer fails at boot rather than at signing.
  """
  @spec load_file!(String.t()) :: t()
  def load_file!(path) when is_binary(path) and path != "" do
    with {:ok, bytes} <- RuntimeConfig.read_secure_file(path, @max_key_file_bytes),
         {:ok, <<_::256>> = seed} <- Base.decode64(String.trim(bytes)) do
      from_seed(seed)
    else
      _ -> raise "invalid edge issuer key file"
    end
  end

  def load_file!(_path), do: raise("edge issuer key file is required")

  @doc "The configured issuer key, or `{:error, :not_configured}` when core issues nothing."
  @spec configured() :: {:ok, t()} | {:error, :not_configured}
  def configured do
    case Application.get_env(:serviceradar_core, :edge_issuer_key) do
      %__MODULE__{} = key -> {:ok, key}
      _ -> {:error, :not_configured}
    end
  end

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
  The gateway trust-file entry for this key: base64 ids and public key, valid for the
  production and source purposes. It carries no private material.
  """
  @spec trust_entry(t()) :: map()
  def trust_entry(%__MODULE__{} = key) do
    %{
      "issuer_id" => Base.encode64(key.issuer_id),
      "issuer_key_id" => Base.encode64(key.key_id),
      "public_key" => Base.encode64(key.public_key),
      "purposes" => ["production", "source"],
      "status" => "valid"
    }
  end

  defp key_id(public_key) do
    <<id::binary-size(16), _::binary>> = :crypto.hash(:sha256, [@key_id_domain, public_key])
    id
  end
end
