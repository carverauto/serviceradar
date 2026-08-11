defmodule ServiceRadar.Notifications.Template.Syntax do
  @moduledoc """
  Save-time validator for the restricted substitution language (design D9).

  Notification subjects and bodies are **not** a programming language. Design D9
  and the "Restricted Templating Language" requirement fix the whole surface:
  whitelisted variable paths plus exactly seven filters - `upper`, `lower`,
  `truncate`, `json`, `url_encode`, `iso8601`, `default`. No EEx, no
  `Code.eval_string/1`, no conditionals beyond `default`, no loops, no
  comparisons, no arithmetic, no module calls, and no `raw/1` on the output.

  The reason the check runs at **save** time rather than at render time is
  operational, not stylistic: a notification template is exercised for the first
  time during an incident. A typo that renders as an empty string, or a filter
  that only fails when the alert finally fires, converts a page into silence at
  the exact moment silence costs the most. So an unknown variable path or an
  unknown filter is a validation error on the write that introduced it.

  ## Syntax

      {{ alert.title }}
      {{ alert.title | truncate: 80 }}
      {{ alert.first_seen_at | iso8601 }}
      {{ alert.severity | upper | default: "unknown" }}

  An expression is a whitelisted variable path followed by zero or more filters
  separated by `|`. `truncate` takes a positive integer; `default` takes a quoted
  string or a number; the remaining filters take no argument.

  ## Variable catalog

  `variable_catalog/0` publishes the exact leaf paths. `open_namespaces/0`
  publishes the prefixes under which operator-owned free-form data (alert
  metadata and labels, the delivery's alert snapshot, device tags) may be
  addressed with any leaf, because those keys are operator data and cannot be
  enumerated at compile time. Everything else must be an exact catalog entry.

  ## What this module does not do

  It does not render. It never evaluates a template, never resolves a path
  against an alert, and never calls `String.to_atom/1`, `apply/3`, `EEx`, or any
  code-evaluation function. Rendering is the renderer's job and is bound by the
  same catalog.

  ## Use as an Ash validation

      validate {ServiceRadar.Notifications.Template.Syntax, attribute: :body_template}

  The validation is atomic-safe: `atomic/3` runs the same pure check against the
  literal value in the changeset, so update actions keep `require_atomic? true`.
  An expression-valued atomic update of a template attribute is refused with
  `{:not_atomic, _}` rather than let through unchecked; a template body computed
  in SQL is not something this validator can inspect, and failing loudly beats
  persisting an unvalidated one.

  Presence in `changeset.atomics` is NOT evidence of an expression, and treating
  it as such is the trap here. On an action with `require_atomic? true` Ash
  rebuilds the changeset through `Ash.Changeset.fully_atomic_changeset/4`, which
  parks every accepted attribute in `changeset.atomics` - including a plain
  literal string. An ordinary `%{body_template: "..."}` update therefore leaves
  nothing for `Ash.Changeset.fetch_change/2` to find, and refusing everything
  found in `atomics` made `NotificationTemplate`'s `:update` and
  `:reconcile_managed` fail outright with `MustBeAtomic`: an operator could not
  edit a template and the seeder could not reconcile one, while every
  database-free test still passed because nothing pure writes a row.
  `ServiceRadar.Notifications.MatchExpression` guards the same boundary the same
  way for the predicate document.

  The literal is read back out and checked. Ash additionally folds the other
  validations' atomic error expressions into each atomic, so on a resource that
  has one the atomic is a `type(...)` cast tree wrapped around the same literal;
  the parameters the atomic changeset was built from still carry it, and it is
  what will be stored, so it is what gets checked. Only a value that is neither
  is genuinely computed, and that is the case `{:not_atomic, _}` exists for.
  """

  use Ash.Resource.Validation

  @filters ~w(upper lower truncate json url_encode iso8601 default)

  # Exact leaf paths. Adding one here is the deliberate act of publishing it to
  # operators; the renderer must be able to resolve every entry.
  @variable_catalog MapSet.new([
                      # The alert itself
                      "alert.id",
                      "alert.title",
                      "alert.message",
                      "alert.description",
                      "alert.severity",
                      "alert.status",
                      "alert.alert_class",
                      "alert.source",
                      "alert.rule_id",
                      "alert.rule_name",
                      "alert.group_key",
                      "alert.dedupe_key",
                      "alert.occurrence_count",
                      "alert.first_seen_at",
                      "alert.last_seen_at",
                      "alert.acknowledged_at",
                      "alert.acknowledged_by",
                      "alert.resolved_at",
                      "alert.resolved_by",
                      "alert.snooze_until",
                      "alert.url",
                      # The subject device, when the alert has one
                      "device.id",
                      "device.uid",
                      "device.name",
                      "device.hostname",
                      "device.ip",
                      "device.mac",
                      "device.partition_id",
                      "device.location",
                      "device.is_active",
                      "device.url",
                      # The rule that produced the alert
                      "rule.id",
                      "rule.name",
                      "rule.category",
                      "rule.severity",
                      "rule.description",
                      # Routing decision
                      "route.id",
                      "route.name",
                      "route.priority",
                      "policy.id",
                      "policy.name",
                      "step.number",
                      "step.delay_seconds",
                      "step.condition",
                      # Destination
                      "channel.id",
                      "channel.name",
                      "channel.execution_route",
                      "provider.key",
                      "provider.display_name",
                      # The delivery record
                      "delivery.id",
                      "delivery.state",
                      "delivery.attempt_count",
                      "delivery.max_attempts",
                      "delivery.occurrence_count",
                      "delivery.dedupe_key",
                      "delivery.payload_format",
                      "delivery.suppression_reason",
                      "delivery.external_correlation_id",
                      # Why the lifecycle emitted this delivery, and the action an
                      # incident API should take because of it. `event_action` is
                      # derived rather than raw precisely because this engine has
                      # no conditionals: a document cannot map renotify onto
                      # trigger itself (task 4.3.3b).
                      "delivery.lifecycle_reason",
                      "delivery.event_action",
                      "delivery.queued_at",
                      "delivery.started_at",
                      "delivery.finished_at",
                      # Signed acknowledgement action links (design D7). The
                      # :stream provider is exempt from emitting these; see D7.
                      "links.acknowledge",
                      "links.snooze",
                      "links.resolve",
                      "links.alert",
                      # Deployment identity
                      "system.name",
                      "system.url",
                      "system.version",
                      "system.now"
                    ])

  # Prefixes whose leaves are operator data and therefore cannot be enumerated.
  # A path under one of these needs at least one segment after the prefix.
  @open_namespaces ~w(alert.metadata alert.labels snapshot device.tags rule.labels)

  # Constructs that mean "somebody expected a programming language here". Each is
  # rejected outright with a message pointing at the Wasm plugin tier, which is
  # the supported answer for expressiveness this engine deliberately lacks.
  @code_markers ["<%", "%>", "{%", "%}", "\#{"]

  @max_template_bytes 64 * 1024
  @max_expressions 200
  @max_filters_per_expression 4
  @max_path_length 200
  @max_truncate 100_000

  @path_regex ~r/^[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z0-9_-]+)*$/
  @quoted_string_regex ~r/^"(?:[^"\\]|\\.)*"$/

  @doc """
  The fixed filter set. There is no eighth filter and no operator-added filter.
  """
  @spec filters() :: [String.t()]
  def filters, do: @filters

  @doc """
  The published exact variable paths, sorted.
  """
  @spec variable_catalog() :: [String.t()]
  def variable_catalog, do: Enum.sort(@variable_catalog)

  @doc """
  Prefixes under which any leaf path is accepted, because the leaves are
  operator-owned free-form data.
  """
  @spec open_namespaces() :: [String.t()]
  def open_namespaces, do: @open_namespaces

  @doc """
  The constructs that mean "somebody expected a programming language here".

  Published so that a caller holding a document rather than a single template -
  `ServiceRadar.Notifications.Declarative.Definition` scans every string in an
  uploaded provider document, not only the template-valued ones - checks for the
  same markers instead of keeping a second list that would drift.
  """
  @spec code_markers() :: [String.t()]
  def code_markers, do: @code_markers

  @doc """
  Validates a subject or body template.

  Returns `:ok`, or `{:error, message}` naming the offending path, filter, or
  construct.

  ## Options

    * `:extra_paths` - additional EXACT variable paths this particular template
      may address, on top of `variable_catalog/0` and `open_namespaces/0`.

  `:extra_paths` exists for the declarative provider tier and for nothing else. A
  declarative definition's `url`, `headers`, and `body` address two namespaces
  that no notification body can: `config.<field>` and `secrets.<field>`, whose
  legal leaves are enumerated by that one document's own `config_schema` and are
  therefore unknown at compile time. They are passed as exact paths rather than
  added to `open_namespaces/0` deliberately - an open namespace accepts any leaf,
  which would put "references a config field the schema does not declare" back
  into the silent-empty-string class this module exists to eliminate. Every other
  caller uses `validate_template/1` and gets the closed catalog unchanged.
  """
  @spec validate_template(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_template(template, opts \\ [])

  def validate_template(nil, _opts), do: :ok
  def validate_template("", _opts), do: :ok

  def validate_template(template, opts) when is_binary(template) and is_list(opts) do
    extra = opts |> Keyword.get(:extra_paths, []) |> MapSet.new()

    with :ok <- check_size(template),
         :ok <- check_code_markers(template),
         {:ok, expressions} <- extract_expressions(template) do
      check_expressions(expressions, extra)
    end
  end

  def validate_template(_other, _opts), do: {:error, "must be a template string"}

  # --- Ash.Resource.Validation ---------------------------------------------

  @impl true
  def init(opts) do
    case Keyword.get(opts, :attribute) do
      attribute when is_atom(attribute) and not is_nil(attribute) ->
        {:ok, opts}

      _other ->
        {:error,
         "#{inspect(__MODULE__)} requires an `:attribute` option naming the template attribute"}
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

    check(value, attribute)
  end

  @impl true
  def atomic(changeset, opts, _context) do
    attribute = Keyword.fetch!(opts, :attribute)

    case fetch_incoming(changeset, attribute) do
      {:ok, value} ->
        check(value, attribute)

      :computed ->
        {:not_atomic,
         "#{inspect(__MODULE__)} cannot validate an expression-valued update of " <>
           "`#{attribute}`; set the template as a literal value"}

      :unset ->
        :ok
    end
  end

  defp fetch_incoming(changeset, attribute) do
    case Ash.Changeset.fetch_change(changeset, attribute) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        case Keyword.fetch(changeset.atomics, attribute) do
          {:ok, value} -> atomic_literal(changeset, attribute, value)
          :error -> :unset
        end
    end
  end

  # The atomic value is normally the literal itself, and is checked directly.
  # It is not always: Ash folds the other validations' atomic error expressions
  # into every atomic, so a resource that grows one turns this into a `type(...)`
  # cast tree wrapped around the same literal. The parameters the atomic
  # changeset was built from still carry that literal, and it is what will be
  # stored, so it is what gets checked. Only a parameter that is not a plain
  # string is genuinely computed.
  defp atomic_literal(changeset, attribute, value) do
    if Ash.Expr.expr?(value) do
      case fetch_param(changeset.params, attribute) do
        {:ok, param} when is_binary(param) or is_nil(param) -> {:ok, param}
        _other -> :computed
      end
    else
      {:ok, value}
    end
  end

  # Parameters arrive with string keys from a form and atom keys from Elixir.
  # Neither is looked up with `String.to_atom/1`: the attribute name is a
  # compile-time atom from the validation's own options.
  defp fetch_param(params, attribute) when is_map(params) do
    case Map.fetch(params, attribute) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(params, Atom.to_string(attribute))
    end
  end

  defp fetch_param(_params, _attribute), do: :error

  defp check(value, attribute) do
    case validate_template(value) do
      :ok -> :ok
      {:error, message} -> {:error, field: attribute, message: message}
    end
  end

  # --- Whole-template checks ------------------------------------------------

  defp check_size(template) do
    if byte_size(template) > @max_template_bytes do
      {:error, "template is larger than #{@max_template_bytes} bytes"}
    else
      :ok
    end
  end

  defp check_code_markers(template) do
    case Enum.find(@code_markers, &String.contains?(template, &1)) do
      nil ->
        :ok

      marker ->
        {:error,
         "template contains the code construct \"#{marker}\"; this engine is restricted " <>
           "substitution only - expressive logic requires a wasm_plugin provider"}
    end
  end

  defp extract_expressions(template) do
    opens = count_occurrences(template, "{{")
    closes = count_occurrences(template, "}}")

    bodies =
      ~r/\{\{(.*?)\}\}/s
      |> Regex.scan(template, capture: :all_but_first)
      |> Enum.map(fn [body] -> body end)

    cond do
      opens != closes ->
        {:error, "template has #{opens} \"{{\" and #{closes} \"}}\"; every expression must close"}

      length(bodies) != opens ->
        {:error, "template has an unbalanced or nested \"{{ }}\" expression"}

      opens > @max_expressions ->
        {:error, "template has more than #{@max_expressions} substitutions"}

      true ->
        {:ok, bodies}
    end
  end

  defp count_occurrences(template, needle) do
    template |> String.split(needle) |> length() |> Kernel.-(1)
  end

  defp check_expressions(bodies, extra) do
    Enum.reduce_while(bodies, :ok, fn body, :ok ->
      case check_expression(body, extra) do
        :ok -> {:cont, :ok}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  # --- One `{{ ... }}` ------------------------------------------------------

  defp check_expression(body, extra) do
    if String.contains?(body, "{") or String.contains?(body, "}") do
      {:error, "nested braces in #{quote_expression(body)}"}
    else
      parse_expression(body, extra)
    end
  end

  defp parse_expression(body, extra) do
    with {:ok, [path_segment | filter_segments]} <- split_pipeline(body),
         :ok <- check_path(String.trim(path_segment), body, extra) do
      check_filters(filter_segments, body)
    end
  end

  defp check_path("", body, _extra),
    do: {:error, "empty variable path in #{quote_expression(body)}"}

  defp check_path(path, body, extra) do
    cond do
      String.length(path) > @max_path_length ->
        {:error, "variable path in #{quote_expression(body)} is too long"}

      not Regex.match?(@path_regex, path) ->
        {:error, "\"#{path}\" in #{quote_expression(body)} is not a variable path"}

      MapSet.member?(@variable_catalog, path) ->
        :ok

      MapSet.member?(extra, path) ->
        :ok

      open_namespace_path?(path) ->
        :ok

      true ->
        {:error,
         "unknown variable path \"#{path}\"; it is not in the published notification " <>
           "variable catalog"}
    end
  end

  defp open_namespace_path?(path) do
    Enum.any?(@open_namespaces, fn namespace ->
      String.starts_with?(path, namespace <> ".") and
        String.length(path) > String.length(namespace) + 1
    end)
  end

  defp check_filters(segments, body) when length(segments) > @max_filters_per_expression do
    {:error, "#{quote_expression(body)} chains more than #{@max_filters_per_expression} filters"}
  end

  defp check_filters(segments, body) do
    Enum.reduce_while(segments, :ok, fn segment, :ok ->
      case check_filter_segment(segment, body) do
        :ok -> {:cont, :ok}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp check_filter_segment(segment, body) do
    case String.split(segment, ":", parts: 2) do
      [name] -> check_filter(String.trim(name), nil, body)
      [name, argument] -> check_filter(String.trim(name), String.trim(argument), body)
    end
  end

  defp check_filter("", _argument, body) do
    {:error, "empty filter in #{quote_expression(body)}"}
  end

  defp check_filter(name, _argument, body) when name not in @filters do
    {:error,
     "unknown filter \"#{name}\" in #{quote_expression(body)}; the fixed filter set is " <>
       Enum.join(@filters, ", ")}
  end

  defp check_filter("truncate", nil, body) do
    {:error, "\"truncate\" in #{quote_expression(body)} requires a length, e.g. `truncate: 80`"}
  end

  defp check_filter("truncate", argument, body) do
    case Integer.parse(argument) do
      {length, ""} when length > 0 and length <= @max_truncate ->
        :ok

      _other ->
        {:error,
         "\"truncate\" in #{quote_expression(body)} takes a positive integer up to #{@max_truncate}"}
    end
  end

  defp check_filter("default", nil, body) do
    {:error,
     "\"default\" in #{quote_expression(body)} requires a fallback, e.g. `default: \"unknown\"`"}
  end

  defp check_filter("default", argument, body) do
    if quoted_string?(argument) or number?(argument) do
      :ok
    else
      {:error,
       "\"default\" in #{quote_expression(body)} takes a quoted string or a number; bare words " <>
         "are not values in this engine"}
    end
  end

  defp check_filter(_name, nil, _body), do: :ok

  defp check_filter(name, _argument, body) do
    {:error, "filter \"#{name}\" in #{quote_expression(body)} does not take an argument"}
  end

  defp quoted_string?(argument), do: Regex.match?(@quoted_string_regex, argument)

  defp number?(argument) do
    match?({_value, ""}, Integer.parse(argument)) or match?({_value, ""}, Float.parse(argument))
  end

  defp quote_expression(body), do: "\"{{#{body}}}\""

  # Splits on `|` while respecting double-quoted filter arguments, so
  # `default: "a|b"` stays one segment.
  defp split_pipeline(body) do
    case do_split(body, [], "", false) do
      {:ok, segments} -> {:ok, segments}
      :unterminated -> {:error, "unterminated string literal in #{quote_expression(body)}"}
    end
  end

  defp do_split(<<>>, acc, current, false), do: {:ok, Enum.reverse([current | acc])}
  defp do_split(<<>>, _acc, _current, true), do: :unterminated

  defp do_split(<<?\\, next::utf8, rest::binary>>, acc, current, true) do
    do_split(rest, acc, current <> <<?\\>> <> <<next::utf8>>, true)
  end

  defp do_split(<<?", rest::binary>>, acc, current, in_string) do
    do_split(rest, acc, current <> "\"", not in_string)
  end

  defp do_split(<<?|, rest::binary>>, acc, current, false) do
    do_split(rest, [current | acc], "", false)
  end

  defp do_split(<<char::utf8, rest::binary>>, acc, current, in_string) do
    do_split(rest, acc, current <> <<char::utf8>>, in_string)
  end
end
