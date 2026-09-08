defmodule ServiceRadar.Notifications.MatchExpression.Evaluator do
  @moduledoc """
  Evaluates a match expression against a subject, as data (design D6, D9).

  `ServiceRadar.Notifications.MatchExpression` is a *validator*: it decides
  whether an operator-authored predicate document is well formed, and says so in
  its own moduledoc that evaluation lives elsewhere. This is elsewhere. Routing
  (`ServiceRadar.Notifications.Router`) and suppression both need the same
  question answered - *does this predicate hold for this alert?* - so it is
  answered once, here.

  ## The grammar is not forked, it is deferred to

  `evaluate/3` calls `MatchExpression.validate_expression/1` first and evaluates
  only a document that validator admitted. That is deliberate and load-bearing:
  the combinator list, the operator list, the operand types, and the structural
  bounds stay in exactly one module. A new operator added to the grammar shows
  up here as a compile-time failure of the parity assertion below rather than as
  a predicate that silently evaluates to `false` in production - which is the
  failure mode that turns a saved route into a route that never pages.

  Passing `validate: false` skips the re-validation for a caller that has
  already validated the same document in the same pass. It does not change
  semantics for a well-formed document; a malformed one then falls through to
  the total fallback clause and yields `false` rather than an error.

  ## Nothing here executes operator input

  No `String.to_atom/1`, no `apply/3`, no `Code.eval_string/1`, no `EEx`. A
  field path is walked as a list of string segments over plain maps, a
  `"matches"` pattern is compiled with `Regex.compile/1` (never
  `Regex.compile!/1`), and every operator is a hard-coded clause head.

  ## Value semantics, which the grammar does not fix

  The validator constrains what an *operand* may be. What a resolved *value* may
  be is decided here, and three rules matter because alert attributes really are
  shaped this way:

  - **Atoms compare as their text.** `alert.severity` is `:critical`, and an
    operator writes `"critical"`. `equals`, `in`, `contains`, and `matches`
    therefore compare against `Atom.to_string/1` of the value. Booleans are the
    exception and compare strictly, so `true` never equals `"true"`.
  - **A list value is existential.** `alert.tags` is `{:array, :string}`, so
    `%{"field" => "alert.tags", "equals" => "prod"}` holds when *any* tag equals
    `"prod"`. The same applies to `in`, `contains`, and `matches`. Without this
    rule the one array attribute on the allow-list would be unmatchable.
  - **Numbers compare numerically.** `alert.metric_value` is a float, so
    `equals: 90` holds for `90.0`, and a string value that parses as a number
    compares numerically against a numeric operand.

  Two absences are distinguished. A path that does not resolve is `:missing`; a
  path that resolves to `nil` is present and empty. `exists` treats both as
  absent - a `nil` attribute is not a value an operator can match on, and every
  Ash attribute is present-with-nil, which would otherwise make `exists: true`
  trivially true for every allow-listed path. `equals: null` holds only for a
  resolved `nil`, never for a missing path.

  ## Subject shape

  The subject is a plain map whose keys are the namespaces the field paths are
  rooted at - `%{"alert" => alert}` for routing. Keys may be strings or atoms
  and values may be structs; `resolve/2` reads both, and never creates an atom
  to do it.
  """

  alias ServiceRadar.Notifications.MatchExpression

  @combinators MatchExpression.combinators()
  @operators MatchExpression.operators()

  # Parity assertions. These exist so that adding an operator or a combinator to
  # the grammar breaks the build here instead of shipping a predicate that
  # always evaluates to false.
  @implemented_combinators ~w(all any not)
  @implemented_operators ~w(equals in contains exists matches)

  if Enum.sort(@implemented_combinators) != Enum.sort(@combinators) do
    raise """
    #{inspect(__MODULE__)} implements combinators #{inspect(Enum.sort(@implemented_combinators))} \
    but ServiceRadar.Notifications.MatchExpression publishes \
    #{inspect(Enum.sort(@combinators))}.

    The grammar and its evaluator must move together: a combinator the validator \
    admits but the evaluator cannot evaluate is a saved route that matches nothing.
    """
  end

  if Enum.sort(@implemented_operators) != Enum.sort(@operators) do
    raise """
    #{inspect(__MODULE__)} implements operators #{inspect(Enum.sort(@implemented_operators))} \
    but ServiceRadar.Notifications.MatchExpression publishes \
    #{inspect(Enum.sort(@operators))}.

    The grammar and its evaluator must move together: an operator the validator \
    admits but the evaluator cannot evaluate is a saved route that matches nothing.
    """
  end

  @type subject :: %{optional(String.t() | atom()) => term()}
  @type resolution :: {:ok, term()} | :missing

  @doc """
  The combinators this evaluator implements, which is exactly the grammar's set.
  """
  @spec combinators() :: [String.t()]
  def combinators, do: @combinators

  @doc """
  The operators this evaluator implements, which is exactly the grammar's set.
  """
  @spec operators() :: [String.t()]
  def operators, do: @operators

  @doc """
  Evaluates `expression` against `subject`.

  Returns `{:ok, boolean}` for a well-formed document and `{:error, message}`
  for one the grammar rejects, so a malformed predicate is a typed outcome the
  caller decides about rather than a crash in the dispatch pipeline.

  Options:

    * `:validate` - re-validate the document against the grammar before
      evaluating it. Defaults to `true`.

  An empty document, and a `nil` document, match everything. That is the same
  rule `NotificationRoute.match_expression` documents for its `%{}` default and
  `NotificationSilence.matchers` documents for its own.
  """
  @spec evaluate(term(), subject(), keyword()) :: {:ok, boolean()} | {:error, String.t()}
  def evaluate(expression, subject, opts \\ [])

  def evaluate(expression, subject, opts) when is_map(subject) do
    if Keyword.get(opts, :validate, true) do
      case MatchExpression.validate_expression(expression) do
        :ok -> {:ok, decide(expression, subject)}
        {:error, message} -> {:error, message}
      end
    else
      {:ok, decide(expression, subject)}
    end
  end

  def evaluate(_expression, _subject, _opts) do
    {:error, "match expression: the evaluation subject must be a map"}
  end

  @doc """
  Resolves a dotted field path against a subject.

  Returns `{:ok, value}` when every segment resolves and `:missing` otherwise.
  A resolved `nil` is `{:ok, nil}`, which is deliberately not the same answer as
  `:missing`.

  Both string and atom keys are read, and structs are read as maps. No atom is
  ever created from the path.
  """
  @spec resolve(subject(), term()) :: resolution()
  def resolve(subject, path) when is_map(subject) and is_binary(path) do
    path
    |> String.split(".")
    |> walk_path(subject)
  end

  def resolve(_subject, _path), do: :missing

  defp walk_path([], value), do: {:ok, value}

  defp walk_path([segment | rest], container) when is_map(container) do
    case fetch_key(container, segment) do
      {:ok, value} -> walk_path(rest, value)
      :error -> :missing
    end
  end

  defp walk_path(_segments, _leaf), do: :missing

  defp fetch_key(container, segment) do
    case Map.fetch(container, segment) do
      {:ok, value} -> {:ok, value}
      :error -> fetch_atom_key(container, segment)
    end
  end

  # `Atom.to_string/1` on a key that already exists creates no atom. The reverse
  # direction is what the Iron Laws forbid and it never happens here.
  defp fetch_atom_key(container, segment) do
    container
    |> plain_map()
    |> Enum.find_value(:error, fn
      {key, value} when is_atom(key) ->
        if Atom.to_string(key) == segment, do: {:ok, value}

      _other ->
        nil
    end)
  end

  defp plain_map(container) when is_struct(container), do: Map.from_struct(container)
  defp plain_map(container) when is_map(container), do: container

  # --- Decision walk --------------------------------------------------------
  #
  # Every clause below runs on a document the grammar already admitted, so the
  # shapes are known. The final fallback exists for `validate: false` callers
  # and answers `false` rather than raising: a predicate that cannot be
  # understood must never claim a match.

  defp decide(nil, _subject), do: true

  defp decide(expression, subject) when is_map(expression) and not is_struct(expression) do
    expression
    |> normalize_keys()
    |> dispatch(subject)
  end

  defp decide(_expression, _subject), do: false

  defp dispatch(normalized, _subject) when map_size(normalized) == 0, do: true

  defp dispatch(%{"all" => branches}, subject) when is_list(branches) do
    branches != [] and Enum.all?(branches, &decide(&1, subject))
  end

  defp dispatch(%{"any" => branches}, subject) when is_list(branches) do
    Enum.any?(branches, &decide(&1, subject))
  end

  defp dispatch(%{"not" => branch}, subject), do: not decide(branch, subject)

  defp dispatch(%{"field" => path} = normalized, subject) do
    case Map.keys(normalized) -- ["field"] do
      [operator] when operator in @operators ->
        test(operator, Map.fetch!(normalized, operator), resolve(subject, path))

      _other ->
        false
    end
  end

  defp dispatch(normalized, subject) when is_map(normalized) do
    Enum.all?(normalized, fn {path, operand} ->
      test("equals", operand, resolve(subject, path))
    end)
  end

  # --- Operators ------------------------------------------------------------

  defp test("exists", operand, resolution) when is_boolean(operand) do
    present?(resolution) == operand
  end

  defp test("exists", _operand, _resolution), do: false

  # Every remaining operator is a test on a value, and a path that does not
  # resolve has no value to test.
  defp test(_operator, _operand, :missing), do: false

  defp test("equals", operand, {:ok, value}) do
    any_value(value, &scalar_equal?(&1, operand))
  end

  defp test("in", operand, {:ok, value}) when is_list(operand) do
    any_value(value, fn element -> Enum.any?(operand, &scalar_equal?(element, &1)) end)
  end

  defp test("in", _operand, _resolution), do: false

  defp test("contains", operand, {:ok, value}) when is_binary(operand) or is_number(operand) do
    case stringify(operand) do
      {:ok, needle} -> any_value(value, &contains_text?(&1, needle))
      :error -> false
    end
  end

  defp test("contains", _operand, _resolution), do: false

  defp test("matches", operand, {:ok, value}) when is_binary(operand) do
    case Regex.compile(operand) do
      {:ok, regex} -> any_value(value, &matches_text?(&1, regex))
      {:error, _reason} -> false
    end
  end

  defp test("matches", _operand, _resolution), do: false

  defp test(_operator, _operand, _resolution), do: false

  defp present?({:ok, nil}), do: false
  defp present?({:ok, _value}), do: true
  defp present?(:missing), do: false

  # A multi-valued attribute holds if the predicate holds for any of its values.
  defp any_value(value, fun) when is_list(value), do: Enum.any?(value, fun)
  defp any_value(value, fun), do: fun.(value)

  defp contains_text?(value, needle) do
    case stringify(value) do
      {:ok, text} -> String.contains?(text, needle)
      :error -> false
    end
  end

  defp matches_text?(value, regex) do
    case stringify(value) do
      {:ok, text} -> Regex.match?(regex, text)
      :error -> false
    end
  end

  # --- Scalar comparison ----------------------------------------------------

  # Booleans are atoms, so they are settled first and strictly. Letting `true`
  # equal `"true"` would make a boolean predicate match a string attribute that
  # happens to read "true", which is not what the operator asked.
  defp scalar_equal?(value, operand) when is_boolean(value) or is_boolean(operand) do
    value === operand
  end

  defp scalar_equal?(nil, operand), do: is_nil(operand)
  defp scalar_equal?(_value, nil), do: false

  defp scalar_equal?(value, operand) when is_number(value) and is_number(operand) do
    value == operand
  end

  defp scalar_equal?(value, operand) when is_binary(operand) do
    case stringify(value) do
      {:ok, text} -> text == operand
      :error -> false
    end
  end

  defp scalar_equal?(value, operand) when is_binary(value) and is_number(operand) do
    case Float.parse(value) do
      {parsed, ""} -> parsed == operand
      _other -> false
    end
  end

  defp scalar_equal?(_value, _operand), do: false

  defp stringify(value) when is_binary(value), do: {:ok, value}
  defp stringify(value) when is_number(value), do: {:ok, to_string(value)}
  defp stringify(%Date{} = value), do: {:ok, Date.to_iso8601(value)}
  defp stringify(%DateTime{} = value), do: {:ok, DateTime.to_iso8601(value)}
  defp stringify(%NaiveDateTime{} = value), do: {:ok, NaiveDateTime.to_iso8601(value)}
  defp stringify(%Time{} = value), do: {:ok, Time.to_iso8601(value)}

  defp stringify(value) when is_atom(value) and not is_nil(value),
    do: {:ok, Atom.to_string(value)}

  defp stringify(_value), do: :error

  defp normalize_keys(map) do
    Map.new(map, fn {key, value} -> {key_to_string(key), value} end)
  end

  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key) when is_atom(key) and not is_nil(key), do: Atom.to_string(key)
  defp key_to_string(key), do: inspect(key)
end
