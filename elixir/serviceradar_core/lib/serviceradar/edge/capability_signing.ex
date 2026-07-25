defmodule Serviceradar.Edge.CapabilitySigning do
  @moduledoc """
  Elixir peer of `go/pkg/edge/edgerecord.CapabilitySigningBytes` +
  `VerifyCapabilitySignature`. It recomputes the canonical signing preimage of an
  `EdgeSignedCapabilityV1` and verifies its Ed25519 signature, so the gateway /
  EventWriter and the cross-language golden fixtures agree on capability signing
  byte-for-byte. The preimage is domain-separated and role-bound; the framing MUST
  match the Go `digestWriter`: a frozen domain tag, big-endian u64, length-framed
  bytes/strings, a u64 claims-oneof discriminant, and field-by-field framing of the
  typed claim message (via `Serviceradar.Edge.ClaimsFraming`) -- NO protobuf
  serialization.
  """

  alias Serviceradar.Edge.ClaimsFraming

  @domain "serviceradar.edge.capability.v1"
  @known_versions [1]
  @known_algorithms ["ed25519"]

  @doc """
  Structural validation mirroring Go `ValidateCapability`: a known version,
  present issuer + key id, a known algorithm, a forward validity window, and a
  typed claims variant equal to `expected_purpose` (`:production` | `:source` |
  `:delivery`). Returns :ok or {:error, reason}.
  """
  @spec validate(map(), atom()) :: :ok | {:error, atom()}
  def validate(cap, expected_purpose) do
    purpose = purpose_of(cap.claims)

    cond do
      cap.capability_version not in @known_versions ->
        {:error, :version}

      byte_size(cap.issuer_id || "") == 0 or byte_size(cap.issuer_key_id || "") == 0 ->
        {:error, :issuer}

      cap.algorithm not in @known_algorithms ->
        {:error, :algorithm}

      (cap.expires_at_unix_nano || 0) <= (cap.not_before_unix_nano || 0) ->
        {:error, :window}

      purpose == nil ->
        {:error, :claims}

      purpose != expected_purpose ->
        {:error, :purpose}

      byte_size(cap.signature || "") == 0 ->
        {:error, :signature}

      true ->
        :ok
    end
  end

  @doc """
  Full verification mirroring Go `VerifyCapabilitySignature`: structural
  `validate/2` for the expected purpose, then Ed25519 verification of the
  signature over `signing_bytes/1`. Returns true only when both pass -- so a
  capability declaring an unsupported algorithm or wrong purpose cannot verify
  even if the raw signature bytes check out.
  """
  @spec verify(map(), atom(), binary()) :: boolean()
  def verify(cap, expected_purpose, public_key) do
    with :ok <- validate(cap, expected_purpose),
         true <- byte_size(public_key) == 32 and byte_size(cap.signature) == 64 do
      :crypto.verify(:eddsa, :none, signing_bytes(cap), cap.signature, [public_key, :ed25519])
    else
      _ -> false
    end
  end

  defp purpose_of({:production, _}), do: :production
  defp purpose_of({:source, _}), do: :source
  defp purpose_of({:delivery, _}), do: :delivery
  defp purpose_of(_), do: nil

  @spec signing_bytes(map()) :: binary()
  def signing_bytes(cap) do
    IO.iodata_to_binary([
      bytes(@domain),
      u64(cap.capability_version || 0),
      bytes(cap.issuer_id),
      bytes(cap.issuer_key_id),
      bytes(cap.algorithm || ""),
      u64(purpose_value(cap.claims)),
      i64(cap.not_before_unix_nano || 0),
      i64(cap.expires_at_unix_nano || 0),
      ClaimsFraming.claims_framed(cap.claims)
    ])
  end

  # EdgeCapabilityPurpose bound into the signing preimage: production=1, source=2,
  # delivery=3. The field-number discriminant (7/8/9) is committed separately by
  # ClaimsFraming.claims_framed, exactly as Go binds both.
  defp purpose_value({:production, _}), do: 1
  defp purpose_value({:source, _}), do: 2
  defp purpose_value({:delivery, _}), do: 3
  defp purpose_value(_), do: 0

  defp u64(v), do: <<v::big-64>>
  defp i64(v), do: <<v::big-signed-64>>
  defp bytes(nil), do: <<0::big-64>>
  defp bytes(b) when is_binary(b), do: [<<byte_size(b)::big-64>>, b]
end
