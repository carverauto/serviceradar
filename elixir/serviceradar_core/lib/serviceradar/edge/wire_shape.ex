defmodule ServiceRadar.Edge.WireShape do
  @moduledoc """
  Does a DECODED struct carry, in every declared field, a term the wire could have produced?
  (task 1.5-h)

  ## Why a struct match is not enough

  Go's generated types make these states unrepresentable: a `uint64` field cannot hold an atom,
  so no validator can be asked about it. In Elixir every generated message is a plain struct
  over `term()`, so a hand-built value can carry `terminal: :bad` or a non-integer sequence.
  Matching `%EdgeLossManifestPageV1{}` proves the struct NAME and nothing about its contents,
  and the field-framed digest helpers then raise `FunctionClauseError` on the first `u64/1` or
  `bytes/1` that meets one -- inside validators whose contract is `{:error, reason}`.

  ## Three ways a shape check fails OPEN, all of them closed here

  1. **The wrong message type.** A field declared `EdgeSourceSpanIdentityV1` holding some OTHER
     generated struct is still "a struct with wire-shaped fields". The DECLARED MODULE is
     compared, so a substituted message is refused rather than passed on to a clause that only
     matches the right one -- which would raise exactly where the shape check promised not to.
  2. **The wrong integer domain.** `is_integer/1` admits `-1` for a `uint64`, and `u64/1` frames
     `-1` identically to the maximum, so two different spans share one preimage. Every
     SUPPORTED integer kind carries its EXACT protobuf range; the rest are refused outright.
  3. **An improper list.** `is_list([1 | :tail])` is true and `Enum.all?/2` then raises on the
     tail, so repeated fields are walked with a proper-list-total traversal.

  ## Fail-closed on anything unrecognised

  An unknown scalar kind is NOT wire-shaped. Treating unrecognised as acceptable would mean a
  proto adding a type this module has not learned silently admits every term in it -- the
  failure this module exists to prevent, arriving quietly.

  ## Descriptor-driven, deliberately

  Declared types come from the GENERATED `__message_props__/0`, never a list written here. A
  hand-written inventory agrees with the proto the day it is written and drifts afterwards.

  ## A NARROW CONTRACT, ENFORCED RATHER THAN DOCUMENTED

  This answers the question only for the FIELD KINDS BELOW, which are exactly those the
  recovery-manifest graph uses:

      bool, bytes, enum, uint32, uint64, and singular or repeated embedded messages

  Anything else -- a map, a float, a string, `sint*`/`fixed*`, a `proto3_optional` scalar --
  is NOT wire-shaped, so a message using one is REFUSED WHOLESALE rather than partly checked.
  That is deliberate and it is the point: the alternative is a helper that looks general,
  silently guesses at kinds it has not implemented, and returns confidently wrong answers.
  Failing closed makes a new caller notice on its first call instead of shipping.

  Completing a kind means implementing it EXACTLY -- a map is not a repeated field, a float32
  must round-trip, a proto3 string must be valid UTF-8, and a declared enum NUMBER is not a
  decoded shape because decoding canonicalises it to its atom. Guessing at any of those is
  worse than refusing, which is why they are not guessed at here.

  ## What this does NOT do

  It makes NO semantic judgement: an enum holding an UNRECOGNISED integer is wire-shaped
  because proto3 enums are OPEN, and a UUID field holding 32 arbitrary bytes is wire-shaped
  whether or not it is a canonical UUID. This answers one question -- could a DECODER have
  produced this term in this field -- and callers keep their own rules.
  """

  # EXACT protobuf ranges, per kind rather than collapsed to `is_integer/1`. The domain IS the
  # point: a negative value in an unsigned field, or one past the width, is a term no encoder
  # could produce and one the digest helpers frame indistinguishably from a legal neighbour.
  @u32 0..4_294_967_295
  @u64 0..18_446_744_073_709_551_615
  @i32 -2_147_483_648..2_147_483_647

  # ONLY the unsigned kinds the recovery graph uses. `int*`/`sint*`/`fixed*`/`sfixed*` are
  # deliberately ABSENT so they fail closed: listing a range for a kind nothing exercises would
  # claim coverage no test holds.
  @int_ranges %{uint32: @u32, uint64: @u64}

  # THE SUPPORTED CLOSURE, COMPUTED AT COMPILE TIME FROM THE ROOT THIS MODULE SERVES.
  #
  # Refusing on the VALUE of an unsupported field is not enough: an EMPTY repeated field of an
  # unsupported kind, or an ABSENT oneof whose members are unsupported, never produces a value
  # to refuse, so a message this module cannot check would pass whenever it happened to be
  # empty. `%BatchGetRequest{keys: []}` passing while `keys: ["x"]` fails is not a contract --
  # it is a coin flip on the input.
  #
  # So the DESCRIPTOR decides, before any value is examined: a module is accepted only if it
  # is in the closure below, and the closure is admitted only if EVERY field kind in it is
  # supported. The walk runs at compile time and RAISES if the recovery graph ever grows a kind
  # this module does not implement -- so that arrives as a build failure with a name in it,
  # rather than as silent refusals in production.
  @root Serviceradar.Edge.V1.EdgeLossManifestPageV1

  @supported_closure (fn ->
                        walk = fn walk, mod, acc ->
                          if MapSet.member?(acc, mod) do
                            acc
                          else
                            acc = MapSet.put(acc, mod)

                            mod.__message_props__().field_props
                            |> Map.values()
                            |> Enum.reduce(acc, fn fp, acc ->
                              cond do
                                fp.map? ->
                                  raise "WireShape: #{inspect(mod)}.#{fp.name_atom} is a MAP, " <>
                                          "which this module does not implement"

                                fp.proto3_optional? ->
                                  raise "WireShape: #{inspect(mod)}.#{fp.name_atom} is " <>
                                          "proto3_optional, which this module does not implement"

                                match?({:enum, _}, fp.type) ->
                                  acc

                                fp.type in [:bool, :bytes, :uint32, :uint64] ->
                                  acc

                                # `embedded?` is the descriptor's OWN answer, so this does not
                                # depend on whether the target module happens to be loaded at
                                # the moment this walk runs.
                                fp.embedded? and
                                    match?({:module, _}, Code.ensure_compiled(fp.type)) ->
                                  walk.(walk, fp.type, acc)

                                true ->
                                  raise "WireShape: #{inspect(mod)}.#{fp.name_atom} has kind " <>
                                          "#{inspect(fp.type)}, which this module does not implement"
                              end
                            end)
                          end
                        end

                        walk.(walk, @root, MapSet.new())
                      end).()

  @doc """
  True when `msg` is one of the SUPPORTED CLOSURE's generated structs and every declared field
  in it holds a wire-shaped term, recursively.

  FALSE FOR ANYTHING OUTSIDE THAT CLOSURE, whatever its contents. This is not a general
  "is this message well-shaped" predicate and SHALL NOT be read as one: it answers only for the
  recovery-manifest graph, and it refuses everything else so a new caller finds out on its
  first call rather than after shipping.

  An absent embedded message (`nil`) is wire-shaped. A repeated field must be a PROPER list
  whose every element is wire-shaped.
  """
  @spec wire_shaped?(term()) :: boolean()
  def wire_shaped?(msg), do: shaped?(msg, :deep)

  @doc """
  True when `msg` is in the SUPPORTED CLOSURE and its own SCALAR fields are wire-shaped,
  ignoring embedded messages, repeated fields and oneof bodies. FALSE for anything outside the
  closure, same as `wire_shaped?/1`.

  Callers use this where a nested fault has its OWN reason: checking a page recursively would
  report a malformed classification body as a page fault, losing the distinction between "this
  page is malformed" and "this span carries a body no consumer can interpret". Each level
  checks itself and lets the level below report its own.
  """
  @spec scalars_wire_shaped?(term()) :: boolean()
  def scalars_wire_shaped?(msg), do: shaped?(msg, :shallow)

  defp shaped?(%mod{} = msg, depth) do
    # THE DESCRIPTOR GATE, before any value is looked at.
    MapSet.member?(@supported_closure, mod) and
      mod.__message_props__().field_props
      |> Map.values()
      |> Enum.all?(&field_ok?(msg, &1, depth))
  end

  defp shaped?(_, _), do: false

  defp field_ok?(_msg, %{oneof: n}, :shallow) when is_integer(n), do: true

  defp field_ok?(msg, %{oneof: n} = fp, :deep) when is_integer(n) do
    # A oneof member is present only under its group's tag; the struct holds
    # `{member_atom, value}` on the GROUP key, so an absent member is not a field violation.
    # An UNDECLARED member atom is refused: the struct would carry a tag the proto never
    # declared, which no decoder produces.
    case oneof_group(msg, n) do
      nil ->
        false

      group ->
        case Map.get(msg, group) do
          nil -> true
          {member, value} -> declared_member(msg, member, n) and member_ok?(member, value, fp)
          _ -> false
        end
    end
  end

  # UNSUPPORTED KINDS, refused rather than guessed at. A map arrives as `repeated?: true` and
  # would enter the list walker, where a legitimately decoded map is not a list of the element
  # type -- so it would be REJECTED while looking checked. A proto3_optional scalar has
  # presence semantics this module does not implement.
  defp field_ok?(_msg, %{map?: true}, _depth), do: false
  defp field_ok?(_msg, %{proto3_optional?: true}, _depth), do: false

  defp field_ok?(_msg, %{repeated?: true}, :shallow), do: true

  defp field_ok?(msg, %{name_atom: name, repeated?: true} = fp, :deep),
    do: all_proper?(Map.get(msg, name), &value_ok?(&1, fp, :deep))

  defp field_ok?(msg, %{name_atom: name} = fp, depth),
    do: value_ok?(Map.get(msg, name), fp, depth)

  # Each field_props entry sees only ITS member; another member's value is that entry's
  # business, and every member is visited because each has its own field_props entry.
  #
  # A SELECTED member may not hold nil. Only an ABSENT WHOLE GROUP is nil (handled above);
  # `{:attributed_active, nil}` is a tag claiming a body that is not there, which no decoder
  # emits -- and the generic nil-is-fine rule for embedded messages would otherwise admit it.
  defp member_ok?(member, nil, %{name_atom: name}), do: member != name

  defp member_ok?(member, value, %{name_atom: name} = fp),
    do: member != name or value_ok?(value, fp, :deep)

  # GROUP-LOCAL. A message may carry several oneof groups, and a member atom belonging to a
  # DIFFERENT group is not a legal tag for this one -- checking membership message-wide would
  # accept it.
  defp declared_member(%mod{}, member, group_index) do
    mod.__message_props__().field_props
    |> Map.values()
    |> Enum.any?(&(&1.name_atom == member and &1.oneof == group_index))
  end

  defp oneof_group(%mod{}, n) do
    case Enum.find(mod.__message_props__().oneof, &(elem(&1, 1) == n)) do
      {group, _} -> group
      _ -> nil
    end
  end

  # PROPER-LIST TOTAL. `Enum.all?/2` raises on an improper tail, which is a shape this module
  # must refuse rather than crash on.
  defp all_proper?([], _fun), do: true
  defp all_proper?([h | t], fun), do: fun.(h) and all_proper?(t, fun)
  defp all_proper?(_not_a_proper_list, _fun), do: false

  # ENUM DISPATCH COMES FIRST. An enum's declared type is a TUPLE, so the `is_atom(t)` nil
  # clause below does not match it and the generic `nil -> true` fallback would have accepted
  # `reason: nil` on a real message. Clause ORDER is the whole guard here.
  #
  # proto3 enums are OPEN, but a DECODER's output is not arbitrary:
  #   * a DECLARED value decodes to its ATOM, never its number -- so a declared number in the
  #     struct is a shape no decoder produces, even though the number is legal on the wire;
  #   * an UNDECLARED value stays a bare integer, bounded by the int32 wire width;
  #   * an atom that is not a declared member is not a decoder output at all;
  #   * `nil` is impossible -- a non-optional enum decodes to its zero value.
  defp value_ok?(v, %{type: {:enum, mod}}, _d) when is_atom(v) and not is_nil(v),
    do: Map.has_key?(mod.mapping(), v)

  defp value_ok?(v, %{type: {:enum, mod}}, _d) when is_integer(v),
    do: v in @i32 and v not in Map.values(mod.mapping())

  defp value_ok?(_v, %{type: {:enum, _}}, _d), do: false

  # An absent embedded message is legal; presence rules belong to the caller. A NON-optional
  # SCALAR is different: protobuf-elixir gives it a zero value, never nil. (proto3_optional
  # fields are refused wholesale above -- their presence semantics are outside this contract.)
  defp value_ok?(nil, %{type: t}, _d) when is_atom(t), do: message_kind?(t)
  defp value_ok?(nil, _fp, _d), do: true

  defp value_ok?(v, %{type: t}, depth) when is_atom(t) do
    cond do
      Map.has_key?(@int_ranges, t) -> is_integer(v) and v in Map.fetch!(@int_ranges, t)
      t == :bool -> is_boolean(v)
      t == :bytes -> is_binary(v)
      # A MODULE: an embedded message. The DECLARED type is compared, so another generated
      # struct in this field is refused rather than silently accepted as "some struct".
      message_kind?(t) -> is_struct(v, t) and (depth == :shallow or shaped?(v, :deep))
      # FAIL CLOSED on a scalar kind this module has not learned.
      true -> false
    end
  end

  defp value_ok?(_v, _fp, _depth), do: false

  defp message_kind?(t),
    do: Code.ensure_loaded?(t) and function_exported?(t, :__message_props__, 0)
end
