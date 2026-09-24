defmodule ServiceRadar.Edge.CapabilityClaims do
  @moduledoc """
  The SINGLE structural predicate for an `EdgeSignedCapabilityV1` claims oneof: is this
  tuple a generated oneof tag paired with that variant's generated body struct?

  Every gate that must answer that question uses `typed?/1` -- capability signature
  verification (`ServiceRadar.Edge.CapabilitySigning`) and the sweep recovery-lane
  preflight (`ServiceRadar.Edge.SweepCorrelate`). Two hand-written copies of the same
  five-member list can disagree, and each would then have to be pinned separately.

  The list is FROZEN here rather than derived from `__message_props__/0` at compile time.
  Derivation cannot drift, but it would silently ADMIT a sixth variant everywhere the
  moment one appeared in the proto -- signable, correlatable, no review. In a frozen ABI a
  new claim variant is a wire change that must be an explicit decision, so the list is
  literal and `capability_claims_test.exs` pins it against
  `EdgeSignedCapabilityV1.__message_props__/0` in BOTH directions. Adding a variant to the
  proto fails that test until this list is updated deliberately.

  A plain map is NOT a claim body: protobuf decoding always produces the struct, so a map
  is a hand-built value that skipped the wire layer. Enforcing that takes more than a
  struct pattern -- `%mod{}` compiles to `%{__struct__: mod}`, so `%{__struct__: Mod}`
  satisfies it, and `is_struct/2` accepts the same map. The FIELD SET is compared as well,
  which is what makes the claim true for anything short of a complete forgery; a complete
  forgery is by construction indistinguishable from a decoded message.

  This matters because fabricated map fixtures have twice hidden defects in these gates:
  a map that clears a predicate a decoded message would not lets a test prove a property
  the runtime does not have.
  """

  @oneof_name :claims

  @variants [
    {:production, Serviceradar.Edge.V1.EdgeProductionClaimsV1},
    {:source, Serviceradar.Edge.V1.EdgeSourceClaimsV1},
    {:delivery, Serviceradar.Edge.V1.EdgeDeliveryClaimsV1},
    {:collection, Serviceradar.Edge.V1.EdgeCollectionClaimsV1},
    {:assignment_execution, Serviceradar.Edge.V1.EdgeAssignmentExecutionClaimsV1}
  ]

  @doc """
  The generated oneof these variants belong to. Pinned so a SECOND oneof on the capability
  cannot make `variants/0` silently ambiguous.
  """
  @spec oneof_name() :: atom()
  def oneof_name, do: @oneof_name

  @doc "The frozen tag/body pairs, in generated field order."
  @spec variants() :: [{atom(), module()}]
  def variants, do: @variants

  @doc """
  True when `claims` is EXACTLY one of the frozen tag/body pairs, carrying that variant's
  generated field set.

  `is_struct/1` alone is not a structural check: it admits `%URI{}`, an unknown tag, and a
  tag paired with the WRONG claim struct. All three are well formed as tuples, so callers
  that only checked struct-ness carried them into gates that assume a usable variant.
  """
  @spec typed?(term()) :: boolean()
  def typed?({tag, %mod{} = body}) do
    {tag, mod} in @variants and Enum.sort(Map.keys(body)) == generated_keys(mod)
  end

  def typed?(_), do: false

  # Read from the generated struct itself, so a variant added to the proto cannot be
  # key-checked against a stale hand-written field list.
  defp generated_keys(mod), do: mod |> struct() |> Map.keys() |> Enum.sort()
end
