defmodule ServiceRadar.Notifications.MatchExpression do
  @moduledoc """
  The one declarative predicate grammar of the notification platform.

  Two resources carry operator-authored predicates over an alert:
  `ServiceRadar.Notifications.NotificationRoute.match_expression` (which alerts a
  route claims) and `ServiceRadar.Notifications.NotificationSilence.matchers`
  (which alerts a maintenance window mutes, design D5). Those are the same
  question asked twice, so they get one grammar and one validator. Two grammars
  would mean two validators kept in semantic parity by hand, and a silence that
  quietly fails to match the route that created it is precisely the "why was I
  not paged?" failure design D5 exists to eliminate.

  ## This module validates shape, and only shape

  It never evaluates an expression against an alert, never resolves a field
  value, and never turns operator input into code. There is no `String.to_atom/1`
  here, no `Code.eval_string/1`, no `EEx`, and no `apply/3`. Evaluation lives in
  the routing and suppression evaluators, which consume the same grammar this
  module admits. Design D9 forbids operator-supplied executable content anywhere
  in the notification path; a validator that had to run an expression to decide
  whether it was well formed would be exactly that.

  Regular expressions supplied under the `"matches"` operator are compiled here
  only to prove the pattern parses. Compiling a pattern is not running it against
  a subject.

  ## Grammar

      expression :=
          %{}                                   # empty object matches everything
        | %{"all" => [expression, ...]}         # conjunction
        | %{"any" => [expression, ...]}         # disjunction
        | %{"not" => expression}                # negation
        | predicate
        | shorthand

      predicate  := %{"field" => path, operator => operand}
      operator   := "equals" | "in" | "contains" | "exists" | "matches"
      shorthand  := %{path => scalar, ...}      # implicit "equals", conjunctive

  A combinator key (`"all"`, `"any"`, `"not"`) must be the only key in its
  object. A predicate carries exactly one operator alongside `"field"`; a
  predicate with no operator is rejected rather than silently demoted to a
  presence test, because that is how a misspelled operator becomes a rule that
  matches everything.

  Operand rules:

    * `"equals"` - a string, number, boolean, or null.
      Routes additionally reject an empty string when saving: `%{}` matches
      every alert, and `equals: ""` matches only a blank value. Evaluation of
      existing routes and silence validation retain empty-string support.
    * `"in"` - a non-empty list of those scalars
    * `"contains"` - a string or a number
    * `"exists"` - a boolean
    * `"matches"` - a regular expression source string that compiles

  Structural bounds (nesting depth, node count, branch count, operand list
  length, path length, pattern length) are enforced so a pasted document cannot
  turn one dispatch decision into an unbounded traversal.

  ## What this module deliberately does not decide

  It checks that `path` is a well-formed dotted attribute path; it does **not**
  decide which paths exist. The resolvable set differs between the routing and
  suppression contexts, so the per-resource allow-list belongs with the resource
  that owns the evaluation context - see
  `ServiceRadar.Notifications.Validations.MatchFieldAllowList`. Passing an
  allow-list to this module is rejected at compile time rather than ignored,
  because an allow-list that is silently dropped is worse than one that was never
  written.

  ## Use as an Ash validation

      validate {ServiceRadar.Notifications.MatchExpression, attribute: :matchers}

      validate {ServiceRadar.Notifications.MatchExpression,
                attribute: :match_expression,
                operators: ~w(equals in exists)}

  Options:

    * `:attribute` (required) - the map attribute holding the document
    * `:operators` - narrows the admitted operator set for this attribute; must
      be a non-empty subset of `operators/0`

  The validation is atomic-safe: `atomic/3` runs the same pure check against the
  literal value in the changeset, so update actions keep `require_atomic? true`.
  An expression-valued atomic update of a predicate attribute is refused with
  `{:not_atomic, _}` rather than let through unchecked; a predicate document
  computed in SQL is not something this validator can inspect, and failing loudly
  beats persisting an unvalidated one.
  """

  use Ash.Resource.Validation

  @combinators ~w(all any not)
  @operators ~w(equals in contains exists matches)
  @known_opts [:attribute, :operators, :reject_empty_equals?]

  @max_depth 10
  @max_nodes 200
  @max_branches 100
  @max_operand_values 200
  @max_path_length 200
  @max_pattern_length 512

  @field_path_regex ~r/^[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z0-9_-]+)*$/

  @doc """
  The combinator keys the grammar admits, for UI predicate builders.
  """
  @spec combinators() :: [String.t()]
  def combinators, do: @combinators

  @doc """
  The predicate operators the grammar admits, for UI predicate builders.

  A builder MUST map a selected operator through this list rather than casting
  operator text into an atom.
  """
  @spec operators() :: [String.t()]
  def operators, do: @operators

  @doc """
  Validates the shape of a match expression or matcher document.

  Accepts `:operators` to narrow the admitted operator set. Returns `:ok`, or
  `{:error, message}` where the message names the offending location so an
  operator can find it inside a nested document.
  """
  @spec validate_expression(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_expression(expression, opts \\ [])

  def validate_expression(nil, _opts), do: :ok

  def validate_expression(expression, opts) do
    allowed = Keyword.get(opts, :operators, @operators)

    case walk(expression, 1, {0, MapSet.new()}, "match expression") do
      {:ok, {_nodes, used}} -> check_operators_allowed(used, allowed)
      {:error, message} -> {:error, message}
    end
  end

  defp check_operators_allowed(used, allowed) do
    case Enum.find(used, &(&1 not in allowed)) do
      nil ->
        :ok

      operator ->
        {:error,
         "operator \"#{operator}\" is not permitted on this attribute; " <>
           "the permitted operators are #{Enum.join(allowed, ", ")}"}
    end
  end

  # --- Ash.Resource.Validation ---------------------------------------------

  @impl true
  def init(opts) do
    with_result =
      with :ok <- validate_known_opts(opts),
           :ok <- validate_attribute_opt(opts) do
        validate_operators_opt(opts)
      end

    case with_result do
      :ok -> {:ok, opts}
      {:error, message} -> {:error, message}
    end
  end

  defp validate_known_opts(opts) do
    case Enum.find(Keyword.keys(opts), &(&1 not in @known_opts)) do
      nil ->
        :ok

      :fields ->
        {:error, allow_list_message(:fields)}

      :field_prefixes ->
        {:error, allow_list_message(:field_prefixes)}

      unknown ->
        {:error,
         "#{inspect(__MODULE__)} got unknown option `#{inspect(unknown)}`; " <>
           "it accepts #{inspect(@known_opts)}"}
    end
  end

  defp allow_list_message(option) do
    "#{inspect(__MODULE__)} owns the predicate grammar, not the field allow-list, " <>
      "so it does not accept `#{inspect(option)}`. Add a second validation using " <>
      "ServiceRadar.Notifications.Validations.MatchFieldAllowList for the paths this " <>
      "resource's evaluation context can resolve."
  end

  defp validate_attribute_opt(opts) do
    case Keyword.get(opts, :attribute) do
      attribute when is_atom(attribute) and not is_nil(attribute) ->
        :ok

      _other ->
        {:error,
         "#{inspect(__MODULE__)} requires an `:attribute` option naming the map attribute to check"}
    end
  end

  defp validate_operators_opt(opts) do
    case Keyword.fetch(opts, :operators) do
      :error ->
        :ok

      {:ok, [_ | _] = operators} ->
        if Enum.all?(operators, &(&1 in @operators)) do
          :ok
        else
          {:error,
           "#{inspect(__MODULE__)} `:operators` must be a subset of #{inspect(@operators)}"}
        end

      {:ok, _other} ->
        {:error, "#{inspect(__MODULE__)} `:operators` must be a non-empty list of operator names"}
    end
  end

  @impl true
  def validate(changeset, opts, _context) do
    attribute = Keyword.fetch!(opts, :attribute)

    value =
      case Ash.Changeset.fetch_change(changeset, attribute) do
        {:ok, value} -> value
        :error -> Map.get(changeset.data, attribute)
      end

    check(value, attribute, opts)
  end

  # `Ash.update/2` runs a `require_atomic?: true` action through
  # `Ash.Changeset.fully_atomic_changeset/4`, which parks every accepted
  # attribute in `changeset.atomics` - including a plain literal map. Treating
  # presence in `atomics` as proof of an expression would therefore refuse every
  # ordinary update of the document with `MustBeAtomic`, so the literal is read
  # back out and only a genuine expression is refused.
  @impl true
  def atomic(changeset, opts, _context) do
    attribute = Keyword.fetch!(opts, :attribute)

    case fetch_incoming(changeset, attribute) do
      {:ok, value} ->
        if Ash.Expr.expr?(value) do
          {:not_atomic,
           "#{inspect(__MODULE__)} cannot validate an expression-valued update of " <>
             "`#{attribute}`; set the predicate document as a literal value"}
        else
          check(value, attribute, opts)
        end

      :error ->
        :ok
    end
  end

  defp fetch_incoming(changeset, attribute) do
    case Ash.Changeset.fetch_change(changeset, attribute) do
      {:ok, value} -> {:ok, value}
      :error -> Keyword.fetch(changeset.atomics, attribute)
    end
  end

  defp check(value, attribute, opts) do
    with :ok <- validate_expression(value, Keyword.take(opts, [:operators])),
         :ok <- validate_empty_equals(value, opts) do
      :ok
    else
      {:error, message} -> {:error, field: attribute, message: message}
    end
  end

  defp validate_empty_equals(value, opts) do
    if Keyword.get(opts, :reject_empty_equals?, false), do: reject_empty_equals(value), else: :ok
  end

  defp reject_empty_equals(expression) when is_map(expression) do
    normalized = Map.new(expression, fn {key, value} -> {key_to_string(key), value} end)

    if Map.has_key?(normalized, "field") and normalized["equals"] == "" do
      {:error,
       "\"equals\" cannot be an empty string; use {} to match every alert, " <>
         "because equals: \"\" matches only a blank value"}
    else
      normalized
      |> Map.take(@combinators)
      |> Map.values()
      |> List.flatten()
      |> Enum.reduce_while(:ok, fn child, :ok ->
        case reject_empty_equals(child) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp reject_empty_equals(_expression), do: :ok

  # --- Shape walk -----------------------------------------------------------

  defp walk(_expression, depth, _acc, where) when depth > @max_depth do
    {:error, "#{where}: nests deeper than #{@max_depth} levels"}
  end

  defp walk(_expression, _depth, {nodes, _used}, where) when nodes >= @max_nodes do
    {:error, "#{where}: has more than #{@max_nodes} predicate nodes"}
  end

  defp walk(expression, depth, {nodes, used}, where)
       when is_map(expression) and not is_struct(expression) do
    case normalize_keys(expression, where) do
      {:ok, normalized} -> dispatch(normalized, depth, {nodes + 1, used}, where)
      {:error, message} -> {:error, message}
    end
  end

  defp walk(_expression, _depth, _acc, where) do
    {:error, "#{where}: expected an object"}
  end

  defp dispatch(normalized, _depth, acc, _where) when map_size(normalized) == 0 do
    {:ok, acc}
  end

  defp dispatch(normalized, depth, acc, where) do
    keys = Map.keys(normalized)

    case Enum.find(@combinators, &(&1 in keys)) do
      nil ->
        if "field" in keys do
          predicate(normalized, keys, acc, where)
        else
          shorthand(normalized, acc, where)
        end

      combinator ->
        combinator_node(combinator, normalized, keys, depth, acc, where)
    end
  end

  defp combinator_node("not", normalized, keys, depth, acc, where) do
    if keys == ["not"] do
      walk(Map.fetch!(normalized, "not"), depth + 1, acc, where <> " -> not")
    else
      {:error, "#{where}: \"not\" must be the only key in its object"}
    end
  end

  defp combinator_node(combinator, normalized, keys, depth, acc, where) do
    if keys == [combinator] do
      branches(Map.fetch!(normalized, combinator), combinator, depth, acc, where)
    else
      {:error, "#{where}: \"#{combinator}\" must be the only key in its object"}
    end
  end

  defp branches([], combinator, _depth, _acc, where) do
    {:error, "#{where}: \"#{combinator}\" must list at least one expression"}
  end

  defp branches(list, combinator, depth, acc, where) when is_list(list) do
    if length(list) > @max_branches do
      {:error, "#{where}: \"#{combinator}\" lists more than #{@max_branches} expressions"}
    else
      list
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, acc}, fn {branch, index}, {:ok, inner} ->
        case walk(branch, depth + 1, inner, "#{where} -> #{combinator}[#{index}]") do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, message} -> {:halt, {:error, message}}
        end
      end)
    end
  end

  defp branches(_other, combinator, _depth, _acc, where) do
    {:error, "#{where}: \"#{combinator}\" must be a list of expressions"}
  end

  defp predicate(normalized, keys, {nodes, used}, where) do
    field = Map.get(normalized, "field")
    operator_keys = keys -- ["field"]

    with :ok <- validate_field_path(field, where),
         {:ok, operator} <- single_operator(operator_keys, where),
         :ok <- validate_operand(operator, Map.fetch!(normalized, operator), where) do
      {:ok, {nodes, MapSet.put(used, operator)}}
    end
  end

  defp single_operator([operator], _where) when operator in @operators, do: {:ok, operator}

  defp single_operator([operator], where) do
    {:error,
     "#{where}: unknown operator \"#{operator}\"; the operator set is " <>
       Enum.join(@operators, ", ")}
  end

  defp single_operator([], where) do
    {:error,
     "#{where}: a predicate needs exactly one operator (#{Enum.join(@operators, ", ")}) " <>
       "alongside \"field\""}
  end

  defp single_operator(operator_keys, where) do
    {:error,
     "#{where}: a predicate carries exactly one operator, got #{length(operator_keys)}; " <>
       "combine them with \"all\""}
  end

  defp validate_operand("equals", operand, where) do
    if scalar?(operand) do
      :ok
    else
      {:error, "#{where}: \"equals\" takes a string, number, boolean, or null"}
    end
  end

  defp validate_operand("in", operand, where) when is_list(operand) do
    cond do
      operand == [] ->
        {:error, "#{where}: \"in\" must list at least one value"}

      length(operand) > @max_operand_values ->
        {:error, "#{where}: \"in\" lists more than #{@max_operand_values} values"}

      not Enum.all?(operand, &scalar?/1) ->
        {:error, "#{where}: \"in\" takes a list of strings, numbers, booleans, or nulls"}

      true ->
        :ok
    end
  end

  defp validate_operand("in", _operand, where) do
    {:error, "#{where}: \"in\" takes a list of values"}
  end

  defp validate_operand("contains", operand, _where)
       when is_binary(operand) or is_number(operand) do
    :ok
  end

  defp validate_operand("contains", _operand, where) do
    {:error, "#{where}: \"contains\" takes a string or a number"}
  end

  defp validate_operand("exists", operand, _where) when is_boolean(operand), do: :ok

  defp validate_operand("exists", _operand, where) do
    {:error, "#{where}: \"exists\" takes true or false"}
  end

  defp validate_operand("matches", operand, where) when is_binary(operand) do
    cond do
      operand == "" ->
        {:error, "#{where}: \"matches\" needs a non-empty pattern"}

      byte_size(operand) > @max_pattern_length ->
        {:error, "#{where}: \"matches\" pattern is longer than #{@max_pattern_length} bytes"}

      true ->
        compile_pattern(operand, where)
    end
  end

  defp validate_operand("matches", _operand, where) do
    {:error, "#{where}: \"matches\" takes a regular expression source string"}
  end

  # Compiling proves the pattern parses. It does not run the pattern against any
  # subject, and nothing here evaluates operator input.
  defp compile_pattern(pattern, where) do
    case Regex.compile(pattern) do
      {:ok, _regex} -> :ok
      {:error, {reason, _position}} -> {:error, "#{where}: invalid pattern - #{reason}"}
      {:error, reason} -> {:error, "#{where}: invalid pattern - #{inspect(reason)}"}
    end
  end

  # Shorthand is implicit "equals", so it is recorded as "equals" in the used set
  # and a resource that narrows `:operators` without it rejects the shorthand
  # form too. Silently exempting shorthand would leave the narrowing bypassable
  # by rewriting the same predicate a shorter way.
  defp shorthand(normalized, {nodes, used}, where) do
    used = if map_size(normalized) > 0, do: MapSet.put(used, "equals"), else: used

    Enum.reduce_while(normalized, {:ok, {nodes, used}}, fn {path, value}, {:ok, inner} ->
      case validate_shorthand_entry(path, value, where) do
        :ok -> {:cont, {:ok, inner}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp validate_shorthand_entry(path, value, where) do
    with :ok <- validate_field_path(path, where) do
      if scalar?(value) do
        :ok
      else
        {:error,
         "#{where}: shorthand value for \"#{path}\" must be a string, number, boolean, or null"}
      end
    end
  end

  defp validate_field_path(path, where) when is_binary(path) do
    cond do
      path == "" ->
        {:error, "#{where}: \"field\" must name an attribute path"}

      String.length(path) > @max_path_length ->
        {:error, "#{where}: field path is longer than #{@max_path_length} characters"}

      not Regex.match?(@field_path_regex, path) ->
        {:error,
         "#{where}: \"#{path}\" is not a dotted attribute path such as \"alert.severity\""}

      true ->
        :ok
    end
  end

  defp validate_field_path(_path, where) do
    {:error, "#{where}: \"field\" must be a string attribute path"}
  end

  defp normalize_keys(map, where) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case key_to_string(key) do
        nil -> {:halt, {:error, "#{where}: object keys must be strings"}}
        binary -> {:cont, {:ok, Map.put(acc, binary, value)}}
      end
    end)
  end

  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key) when is_atom(key) and not is_nil(key), do: Atom.to_string(key)
  defp key_to_string(_key), do: nil

  defp scalar?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: true

  defp scalar?(_value), do: false
end
