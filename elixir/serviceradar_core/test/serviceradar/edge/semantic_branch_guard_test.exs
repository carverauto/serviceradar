defmodule ServiceRadar.Edge.SemanticBranchGuardTest do
  @moduledoc """
  THE STATIC GUARD, THIS RUNTIME'S HALF.

  Everything else in the semantic-envelope suite is FINITE EVIDENCE, and finite evidence over a
  grammar that may branch on arbitrary payload values can always be evaded by one more unmodeled
  predicate. The committed cross product is exhaustive over the DECLARED structural axes -- carrier
  presence and oneof discriminants -- and this check is defense in depth on the shape that
  enumeration assumes, not the thing that makes it complete.

  GO HAD SUCH A CHECK AND THIS RUNTIME HAD NONE, so one side of a cross-runtime contract had a
  regression check on its framing shape and the other had nothing at all. Measured: omitting `output_contract` only when
  `projected_row_count == 42` passed every corpus test here and collapsed the present and absent
  digests together.

  DEFENSE IN DEPTH, NOT A PROOF, AND THESE ARE ITS LIMITS: it reads function BODIES. It does not
  resolve FUNCTION HEADS or GUARDS, so a two-clause helper matching `%{projected_row_count: 42}`
  is invisible to it; it does not expand MACROS; and it cannot resolve REMOTE CALLS it has not
  been told about. The committed cross product is exhaustive over the DECLARED carrier and oneof
  axes, not over every Elixir program. Closing that needs a descriptor-validated declarative
  grammar that GENERATES both framers, recorded in design.md as an UNOWNED follow-up.

  THE RULE IS STRICTER HERE THAN IN GO, because this runtime needs no in-body branching at all:
  both framer modules today express every alternative through FUNCTION HEADS -- a `nil` clause and
  a populated clause, a clause per oneof tag. So `if`, `case`, `cond`, `unless`, `with` and
  comprehensions are simply forbidden in them. The COMPARISON rules are narrow: a `||` nil-default
  must have a LITERAL right-hand side, and `==`/`!=` may only compare against `nil`. The
  structural allowlist is wider than that sentence alone suggests -- it also admits `and`, `or`
  and `not` alongside binding and bitstring syntax. `and` and `or` SHORT-CIRCUIT, so they can gate
  whether their right operand is evaluated at all; admitting them is a known hole, not a proof
  that they are harmless. Their actual uses today are NUMERIC RANGE GUARDS on the primitives --
  `when is_integer(v) and v >= 0 and v <= @u64_max` -- which is a width check on one value, not a
  choice between two write orders. This check does not verify that, and does not read guards at
  all.
  """
  use ExUnit.Case, async: true

  @framer_sources ["semantic_digest.ex", "claims_framing.ex"]

  # No branching construct may appear in a framer module.
  @forbidden_forms [:if, :case, :cond, :unless, :with, :for, :receive, :try]

  # SYNTAX AND PURE OPERATORS, NOT CALLS. These cannot select between two write orders: `=` binds,
  # `::`/`<<>>`/`-` are bitstring construction (`<<v::big-64>>` parses the size modifier as a
  # subtraction), and arithmetic changes what is written, never the sequence. The threat this
  # guard exists for is a PREDICATE choosing an order, so these are out of scope -- and listing
  # them beats a blanket "ignore operators", which would also excuse a comparison.
  @structural_forms [
    :__block__,
    :__aliases__,
    :.,
    :%{},
    :%,
    :{},
    :|>,
    :@,
    :when,
    :"::",
    :->,
    :<<>>,
    :=,
    :-,
    :+,
    :*,
    :<>,
    :++,
    :and,
    :or,
    :not
  ]

  # The calls a framer may make BY BARE NAME: its own primitives and framers, the generated enum
  # accessors, and the guards used in function heads. Widening this is a deliberate act -- an
  # unlisted bare-name call is a place for framing order to depend on a payload value out of
  # sight. It is NOT the only call surface: a REMOTE call (`Mod.fun(...)`) never reaches this
  # list, because it parses with a `.` tuple where an atom name would be. Measured:
  # `Map.get(r, :output_contract)` passes.
  @allowed_calls ~w(
    u64 i64 bytes present opt_u64 enum
    output_contract claims_framed collection_claims production_claims source_claims
    delivery_claims execution_grant_claims capability source_auth producer_context
    source_identity transition compute
    byte_size is_atom is_binary is_integer is_nil is_map value
  )a

  test "framing order branches ONLY on the declared structural axes" do
    violations = Enum.flat_map(@framer_sources, &check_source/1)

    assert violations == [],
           "#{length(violations)} framer constructs are outside the declared structural axes. " <>
             "Framing order may depend ONLY on carrier presence and oneof discriminants, both " <>
             "expressed through function heads -- anything else is a predicate no finite set of " <>
             "committed vectors can be complete against:\n  " <> Enum.join(violations, "\n  ")
  end

  defp check_source(name) do
    ast =
      name
      |> framer_path()
      |> File.read!()
      |> Code.string_to_quoted!(columns: true)

    # A CALL TO A FUNCTION DEFINED IN THIS MODULE IS FINE, because this walk reads that function's
    # BODY too. That is narrower than it sounds: a local helper can still branch through its
    # FUNCTION HEADS or GUARDS, which this walk does not read -- a two-clause helper matching
    # `%{projected_row_count: 42}` is invisible to it. A call to anything else is rejected unless
    # it is on the primitive allowlist -- which is where `output_contract(c, some_predicate(r))`
    # would put a branch. A REMOTE call is not matched at all: `Mod.fun(args)` parses with a `.`
    # tuple where an atom name would be, so it misses the name check entirely and only its
    # ARGUMENTS are walked -- measured, `Map.get(r, :output_contract)` passes. This narrows where
    # a branch can hide; it does not establish that none can.
    local = defined_names(ast)

    ast
    |> collect_bodies()
    |> Enum.flat_map(&walk(&1, name, local))
  end

  defp defined_names(ast) do
    {_, names} =
      Macro.prewalk(ast, MapSet.new(), fn
        {kind, _, [head | _]} = node, acc when kind in [:def, :defp] ->
          {node, put_name(acc, head)}

        node, acc ->
          {node, acc}
      end)

    names
  end

  # A GUARDED CLAUSE WRAPS ITS HEAD IN `when`, so `defp origin_kind(k) when is_atom(k)` reads as a
  # definition of `when` unless it is unwrapped -- and the helper then looked like an outside call.
  defp put_name(acc, {:when, _, [inner | _]}), do: put_name(acc, inner)
  defp put_name(acc, {name, _, _}) when is_atom(name), do: MapSet.put(acc, name)
  defp put_name(acc, _), do: acc

  # A GUARD THAT CANNOT READ ITS SUBJECT MUST FAIL, NOT SKIP: a missing file would yield no
  # violations, which is the same green as a clean tree.
  defp framer_path(name) do
    candidates = [
      Path.join([__DIR__, "..", "..", "..", "lib", "serviceradar", "edge", name]),
      Path.join([File.cwd!(), "lib", "serviceradar", "edge", name]),
      Path.join([File.cwd!(), "elixir", "serviceradar_core", "lib", "serviceradar", "edge", name])
    ]

    Enum.find(candidates, &File.exists?/1) ||
      flunk("cannot locate framer source #{name}; tried #{inspect(candidates)}")
  end

  # Only function BODIES are policed. Typespecs and docs legitimately mention types and text that
  # would otherwise read as calls.
  defp collect_bodies(ast) do
    {_, bodies} =
      Macro.prewalk(ast, [], fn
        {def_kind, _, [_head, [do: body]]} = node, acc when def_kind in [:def, :defp] ->
          {node, [body | acc]}

        node, acc ->
          {node, acc}
      end)

    bodies
  end

  defp walk(body, source, local) do
    {_, violations} =
      Macro.prewalk(body, [], fn node, acc -> {node, acc ++ inspect_node(node, source, local)} end)

    violations
  end

  defp inspect_node({form, meta, _args}, source, _local) when form in @forbidden_forms,
    do: ["#{source}:#{meta[:line]}: `#{form}` may not appear in a framer"]

  # `x || literal` is a NIL DEFAULT, not a branch on a payload value. `x || some_predicate(y)` is.
  defp inspect_node({:||, meta, [_left, right]}, source, _local) do
    if literal?(right),
      do: [],
      else: ["#{source}:#{meta[:line]}: `||` right-hand side is not a literal default"]
  end

  defp inspect_node({op, meta, [left, right]}, source, _local) when op in [:==, :!=] do
    if left == nil or right == nil,
      do: [],
      else: ["#{source}:#{meta[:line]}: `#{op}` compares something other than nil"]
  end

  defp inspect_node({name, meta, args}, source, local) when is_atom(name) and is_list(args) do
    cond do
      name in @allowed_calls ->
        []

      MapSet.member?(local, name) ->
        []

      # struct/map access, blocks, pipes and other syntax nodes are not calls
      name in @structural_forms ->
        []

      String.starts_with?(Atom.to_string(name), "_") ->
        []

      true ->
        ["#{source}:#{meta[:line]}: calls `#{name}`, which is outside the framer surface"]
    end
  end

  defp inspect_node(_node, _source, _local), do: []

  defp literal?(v) when is_integer(v) or is_binary(v) or is_atom(v) or is_float(v), do: true
  defp literal?(_), do: false
end
