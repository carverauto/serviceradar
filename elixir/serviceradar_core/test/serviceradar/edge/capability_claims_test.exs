defmodule ServiceRadar.Edge.CapabilityClaimsTest do
  @moduledoc """
  The frozen claim-variant list is pinned against GENERATED oneof metadata, not against
  another hand-written list. Two handwritten lists agreeing proves only that the same
  author wrote both: a sixth generated variant could be absent from each and be classified
  as malformed by every gate.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.CapabilityClaims
  alias Serviceradar.Edge.V1, as: V1

  # Derived from the generated message, so this side of the comparison cannot be edited
  # into agreement with the frozen list.
  defp generated_variants do
    props = V1.EdgeSignedCapabilityV1.__message_props__()

    props.field_props
    |> Map.values()
    |> Enum.filter(&(&1.oneof != nil))
    |> Enum.sort_by(& &1.fnum)
    |> Enum.map(&{&1.name_atom, &1.type})
  end

  test "the capability has exactly ONE oneof, and it is the pinned one" do
    # `generated_variants/0` filters on oneof membership alone. A second oneof would merge
    # its members into that list, making the pin below compare an ambiguous set.
    props = V1.EdgeSignedCapabilityV1.__message_props__()
    assert props.oneof == [{CapabilityClaims.oneof_name(), 0}]
  end

  test "the frozen list and the generated oneof agree in BOTH directions" do
    frozen = CapabilityClaims.variants()
    generated = generated_variants()

    # Direction 1: nothing generated is missing from the frozen list. This is the failure
    # the reviewer named -- a new variant silently treated as malformed everywhere.
    assert generated |> MapSet.new() |> MapSet.difference(MapSet.new(frozen)) |> MapSet.to_list() ==
             [],
           "the proto grew a claim variant; add it to CapabilityClaims deliberately"

    # Direction 2: nothing frozen has been removed or renamed in the proto.
    assert frozen |> MapSet.new() |> MapSet.difference(MapSet.new(generated)) |> MapSet.to_list() ==
             [],
           "a frozen claim variant is no longer in the generated oneof"

    # Order too: `variants/0` documents itself as generated field order.
    assert frozen == generated
  end

  test "each generated body type is a real protobuf message, not just an atom" do
    # Guards the pin itself: if `f.type` were ever a scalar or a stale module, the equality
    # above could still hold while `typed?/1` matched nothing constructible.
    for {tag, mod} <- CapabilityClaims.variants() do
      assert Code.ensure_loaded?(mod) and function_exported?(mod, :__message_props__, 0),
             "#{inspect(tag)} body #{inspect(mod)} is not a generated message"

      assert CapabilityClaims.typed?({tag, struct(mod)}),
             "#{inspect(tag)} does not satisfy the predicate it is frozen for"
    end
  end

  describe "typed?/1 is structural, not merely struct-ness" do
    test "an arbitrary struct under a valid tag is refused" do
      refute CapabilityClaims.typed?({:source, %URI{}})
    end

    test "an unknown tag with a valid body is refused" do
      refute CapabilityClaims.typed?({:bogus_tag, %V1.EdgeSourceClaimsV1{}})
    end

    test "a valid tag paired with the WRONG generated body is refused" do
      refute CapabilityClaims.typed?({:source, %V1.EdgeProductionClaimsV1{}})
    end

    test "a map body is refused -- decoding always produces the struct" do
      refute CapabilityClaims.typed?({:source, %{}})

      # `%mod{}` in a PATTERN compiles to `%{__struct__: mod}`, and `is_struct/2` accepts
      # the same shape, so this map clears every struct-based check. Only comparing the
      # field set refuses it.
      refute CapabilityClaims.typed?({:source, %{__struct__: V1.EdgeSourceClaimsV1}})

      # A partial forgery: correct tag, correct __struct__, one generated field missing.
      partial = V1.EdgeSourceClaimsV1 |> struct() |> Map.delete(:__unknown_fields__)
      refute CapabilityClaims.typed?({:source, partial})
    end

    test "a DECODED body is accepted -- the field-set check is not vacuous" do
      # The control for the refutations above: the check must refuse forgeries without
      # also refusing what the wire actually produces.
      decoded =
        %V1.EdgeSourceClaimsV1{}
        |> V1.EdgeSourceClaimsV1.encode()
        |> V1.EdgeSourceClaimsV1.decode()

      assert CapabilityClaims.typed?({:source, decoded})
    end

    test "non-oneof shapes are refused without raising" do
      for bad <- [nil, :source, {}, {:source}, {:source, %V1.EdgeSourceClaimsV1{}, :extra}, 7, []] do
        refute CapabilityClaims.typed?(bad), "#{inspect(bad)} was accepted"
      end
    end
  end
end
