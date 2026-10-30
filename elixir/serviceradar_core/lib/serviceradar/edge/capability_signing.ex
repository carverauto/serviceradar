defmodule ServiceRadar.Edge.CapabilitySigning do
  @moduledoc """
  Elixir peer of `go/pkg/edge/edgerecord.CapabilitySigningBytes` +
  `VerifyCapabilitySignature`. It recomputes the canonical signing preimage of an
  `EdgeSignedCapabilityV1` and verifies its Ed25519 signature, so the gateway /
  EventWriter and the cross-language golden fixtures agree on capability signing
  byte-for-byte. The preimage is domain-separated and role-bound; the framing MUST
  match the Go `digestWriter`: a frozen domain tag, big-endian u64, length-framed
  bytes/strings, a u64 claims-oneof discriminant, and field-by-field framing of the
  typed claim message (via `ServiceRadar.Edge.ClaimsFraming`) -- NO protobuf
  serialization.
  """

  alias ServiceRadar.Edge.ClaimsFraming
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1

  @domain "serviceradar.edge.capability.v1"
  @known_versions [1]
  @known_algorithms ["ed25519"]
  @u64_max 0xFFFF_FFFF_FFFF_FFFF
  @i64_min -0x8000_0000_0000_0000
  @i64_max 0x7FFF_FFFF_FFFF_FFFF

  @doc """
  Structural validation mirroring Go `ValidateCapability`: NO retained unknown protobuf fields
  (recursively, on the capability OR any nested claim/oneof member -- they sit outside the
  field-framed signature, so a later reader could reinterpret a signed claim), a known
  version, present issuer + key id, a known algorithm, a forward validity window, and a typed
  claims variant equal to `expected_purpose` (`:production` | `:source` | `:delivery` |
  `:collection` | `:assignment_execution`). Returns
  :ok or {:error, reason}.
  """
  @typedoc """
  Every reason `validate/2` returns.

  EXPORTED so callers reference it instead of copying the list: a hand-copied union in a
  caller silently drifts the moment a reason is added here, and a caller matching
  exhaustively then crashes on a shape its own contract said could not occur.
  """
  @type reason ::
          :unknown_fields
          | :version
          | :issuer
          | :algorithm
          | :window
          | :claims
          | :purpose
          | :signature
          | :capability

  # `term()`, not `map()`: the fallback clause, the comments and the committed tests all promise
  # a typed error for ANY input, so a `map()` spec put `validate(:nope, ...)` outside the
  # contract -- Dialyzer would call the totality clause and its tests unreachable, which is the
  # opposite of what they exist to prove.
  @spec validate(term(), atom()) :: :ok | {:error, reason()}
  # REQUIRES the generated struct, not merely a map. A plain map is not a weaker input, it is a
  # BYPASS: `unknown_fields_clean?/1` matches on `__unknown_fields__`, so a map without that key
  # falls through to `true` and the recursive walk NEVER REACHES the nested claim. Retained
  # unknown bytes inside a perfectly typed claim were therefore accepted whenever the envelope
  # around it was hand-built. Protobuf decoding always yields the struct, so a map reached here
  # by skipping the wire layer -- exactly where those bytes live.
  #
  # The `validate(_, _)` fallback below keeps this total: a non-struct is `{:error, :capability}`,
  # never a raise.
  def validate(%EdgeSignedCapabilityV1{} = cap, expected_purpose) do
    nb = Map.get(cap, :not_before_unix_nano)
    ex = Map.get(cap, :expires_at_unix_nano)
    sig = Map.get(cap, :signature)
    purpose = purpose_of(Map.get(cap, :claims))

    cond do
      not unknown_fields_clean?(cap) ->
        {:error, :unknown_fields}

      Map.get(cap, :capability_version) not in @known_versions ->
        {:error, :version}

      not (nonempty_binary?(Map.get(cap, :issuer_id)) and
               nonempty_binary?(Map.get(cap, :issuer_key_id))) ->
        {:error, :issuer}

      Map.get(cap, :algorithm) not in @known_algorithms ->
        {:error, :algorithm}

      # Fixed-width alias defense: not_before/expires MUST be in-range int64 BEFORE any signing
      # preimage, else <<v::big-signed-64>> truncates them (2^100 and 2^100+1 alias to 0 and 1).
      not (i64?(nb) and i64?(ex)) ->
        {:error, :window}

      ex <= nb ->
        {:error, :window}

      purpose == nil ->
        {:error, :claims}

      # The claim BODY must be the generated struct for its variant. `{:collection, 7}` is a
      # well-formed oneof shape as far as the tuple goes, so purpose derivation succeeds and
      # every later `Map.get/2` then raises BadMapError -- a contract promising
      # `{:error, reason}` must not raise on a shape it did not anticipate.
      not ServiceRadar.Edge.CapabilityClaims.typed?(Map.get(cap, :claims)) ->
        {:error, :claims}

      purpose != expected_purpose ->
        {:error, :purpose}

      not nonempty_binary?(sig) ->
        {:error, :signature}

      true ->
        :ok
    end
  end

  def validate(_, _), do: {:error, :capability}

  defp nonempty_binary?(b), do: is_binary(b) and byte_size(b) > 0
  defp i64?(v), do: is_integer(v) and v >= @i64_min and v <= @i64_max

  # Recursively true when NO retained unknown protobuf fields exist on the capability or any nested
  # message / oneof member (outside the field-framed signature). Mirrors Go recursive hasUnknownFields.
  defp unknown_fields_clean?(%{__unknown_fields__: uf} = msg) do
    uf == [] and Enum.all?(nested_messages(msg), &unknown_fields_clean?/1)
  end

  defp unknown_fields_clean?(_), do: true

  # Only STRUCTS have nested protobuf messages -- Map.from_struct/1 raises on a plain map (e.g. a
  # poison `%{__unknown_fields__: []}`), so guard it.
  defp nested_messages(msg) when is_struct(msg) do
    msg
    |> Map.from_struct()
    |> Map.values()
    |> Enum.flat_map(fn
      %{__struct__: _} = child -> [child]
      {_tag, %{__struct__: _} = child} -> [child]
      list when is_list(list) -> Enum.filter(list, &is_struct/1)
      _ -> []
    end)
  end

  defp nested_messages(_), do: []

  @doc """
  Full verification mirroring Go `VerifyCapabilitySignature`: structural
  `validate/2` for the expected purpose, then Ed25519 verification of the
  signature over `signing_bytes/1`. Returns true only when both pass -- so a
  capability declaring an unsupported algorithm or wrong purpose cannot verify
  even if the raw signature bytes check out.
  """
  # `term()` for the same reason: verify/3 rescues and returns false for any shape.
  @spec verify(term(), atom(), term()) :: boolean()
  def verify(cap, expected_purpose, public_key) do
    sig = if is_map(cap), do: Map.get(cap, :signature)

    with :ok <- validate(cap, expected_purpose),
         true <- is_binary(public_key) and byte_size(public_key) == 32,
         true <- is_binary(sig) and byte_size(sig) == 64 do
      :crypto.verify(:eddsa, :none, signing_bytes(cap), sig, [public_key, :ed25519])
    else
      _ -> false
    end
  rescue
    # signing_bytes/1 frames claim fields that validate/2 does not deeply width-check (e.g. a
    # constructed authority_epoch = -1); a framing raise must never escape verification.
    _ -> false
  catch
    _kind, _reason -> false
  end

  @doc """
  The ROLE a capability fills, derived from which typed claims variant is set, or `nil`.

  PUBLIC so a caller can answer the role BEFORE anything else: deriving it only inspects which
  oneof member is set -- no framing, no hashing, no field reads -- so a wrong-role capability
  can be reported as exactly that rather than as whichever envelope rule happens to fail first.
  `validate/2` checks version, issuer and algorithm before purpose, which is right for its own
  contract but wrong for a caller whose first question is "is this even the right kind".
  """
  @spec purpose(term()) :: atom() | nil
  def purpose(%EdgeSignedCapabilityV1{claims: claims}), do: purpose_of(claims)
  def purpose(_), do: nil

  defp purpose_of({:production, _}), do: :production
  defp purpose_of({:source, _}), do: :source
  defp purpose_of({:delivery, _}), do: :delivery
  defp purpose_of({:collection, _}), do: :collection
  defp purpose_of({:assignment_execution, _}), do: :assignment_execution
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
  # delivery=3, collection=4, assignment_execution=5. The field-number discriminant
  # (7/8/9/11/12) is committed separately by ClaimsFraming.claims_framed, exactly as Go binds
  # both.
  #
  # A MISSING CASE HERE IS A SIGNING BUG, not merely a validation gap: purpose is IN the
  # preimage, so an unlisted variant signs purpose 0 and the official verifier then rejects it.
  # Both new variants were added here at the same time as their framing for that reason.
  defp purpose_value({:production, _}), do: 1
  defp purpose_value({:source, _}), do: 2
  defp purpose_value({:delivery, _}), do: 3
  defp purpose_value({:collection, _}), do: 4
  defp purpose_value({:assignment_execution, _}), do: 5
  defp purpose_value(_), do: 0

  # CHECKED framing primitives: an out-of-range integer would silently truncate under a fixed-width
  # bitstring (a signing alias), so the width is guarded -- an out-of-range value fails loudly
  # instead of producing an aliased preimage. (Valid decoded protobuf is always in range.)
  defp u64(v) when is_integer(v) and v >= 0 and v <= @u64_max, do: <<v::big-64>>
  defp i64(v) when is_integer(v) and v >= @i64_min and v <= @i64_max, do: <<v::big-signed-64>>
  defp bytes(nil), do: <<0::big-64>>
  defp bytes(b) when is_binary(b), do: [<<byte_size(b)::big-64>>, b]
end
