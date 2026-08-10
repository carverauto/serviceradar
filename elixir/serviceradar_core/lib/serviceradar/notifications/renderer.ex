defmodule ServiceRadar.Notifications.Renderer do
  @moduledoc """
  Turns an alert snapshot plus a resolved `NotificationTemplate` into the payload
  a transport sends, the digest the delivery row stores, and the
  `payload_format` actually used (design D9, tasks 1.4.5 / 1.4.6 / 1.4.6a).

  ## Pure, and `now` is an input

  Rendering is a pure function. It performs no query, holds no process state, and
  never calls `DateTime.utc_now/0`: the alert snapshot, the template, the format,
  and every contextual value including `system.now` are passed in. The caller
  loads, renders, and persists; this module only decides what the bytes are.
  That is what makes the semantics below testable with `async: true` and no
  database.

  ## Substitution is restricted, and the grammar is not defined twice

  `ServiceRadar.Notifications.Template.Syntax` owns the language: the variable
  catalog, the open namespaces, and the seven filters (`upper`, `lower`,
  `truncate`, `json`, `url_encode`, `iso8601`, `default`). This module owns
  evaluation only, and it runs `Syntax.validate_template/1` on every template
  before evaluating it, so a template that would not have saved cannot render
  either. There is no EEx, no `Code.eval_string/1`, no `String.to_atom/1`, and no
  `raw/1`.

  ## An unresolvable variable is reported, never raised, never silent

  A path that is missing, or present but nil, renders as an empty string AND is
  recorded in `Rendered.unresolved`. Both halves matter:

    * Raising would turn a typo into a lost page during an incident.
    * Silently emitting `""` is the exact failure `Syntax` runs at save time to
      prevent, and the save-time check cannot see everything - an alert simply
      may not carry `device.hostname`. So the render result carries the evidence
      forward instead of discarding it.

  A `default:` filter that supplies a substitute is still reported, flagged
  `default_applied?: true`, because "the operator handled this" and "nothing was
  there" are different facts and only the first is benign.

  ## Format negotiation is a hard boundary

  A channel is NEVER asked for a `payload_format` its provider does not declare.
  `:supported_formats` is a required option for exactly that reason, and asking
  for a format outside it is a typed error rather than a best-effort fallback: a
  provider that receives Slack blocks in a field expecting Markdown answers 400,
  which is a permanent failure, so guessing loses the notification.

  With no explicit target the richest declared format wins, in the fixed order
  `#{inspect([:slack_blocks, :discord_embed, :pagerduty_v2, :json, :html, :markdown, :plain])}`.

  ## Redaction, and what the digest covers

  Every rendered payload passes `ServiceRadar.Automation.Northbound.ActionRedaction`
  (policy `northbound-action-redaction-v1`) before it can be persisted or logged.
  The result therefore carries two payloads:

    * `payload` - what the transport sends. It is the notification, so it is not
      redacted; redacting it would mail `[REDACTED]` to the on-call engineer.
    * `redacted_payload` - the only form that may be persisted or displayed.

  `digest` is computed over the **redacted** payload, and that choice is
  deliberate. Action links carry a per-delivery single-use capability token, so a
  digest over the sent bytes would differ on every render of identical content
  and could not answer the question the column exists for - "did these two
  deliveries carry the same thing?". Hashing the redacted form also guarantees no
  secret is fed into the hash at all.

  `:sensitive_values` lets the caller name strings - minted capability tokens,
  resolved webhook URLs - that must not survive into `redacted_payload`.
  `ActionRedaction` matches on key names, and a token embedded in a `url` value
  has no sensitive key to match, so it needs this second, value-based pass.

  See `openspec/changes/add-notification-platform/design.md` (D2, D7, D9).
  """

  alias ServiceRadar.Automation.Northbound.ActionRedaction
  alias ServiceRadar.Notifications.ActionLinks
  alias ServiceRadar.Notifications.Renderers.Content
  alias ServiceRadar.Notifications.Renderers.DiscordEmbed
  alias ServiceRadar.Notifications.Renderers.Format
  alias ServiceRadar.Notifications.Renderers.Html
  alias ServiceRadar.Notifications.Renderers.Json
  alias ServiceRadar.Notifications.Renderers.Markdown
  alias ServiceRadar.Notifications.Renderers.PagerdutyV2
  alias ServiceRadar.Notifications.Renderers.Plain
  alias ServiceRadar.Notifications.Renderers.SlackBlocks
  alias ServiceRadar.Notifications.Template.Syntax

  # Declaration order IS the negotiation preference: richest first. Resolution is
  # a compile-time keyword lookup, never String.to_atom/1.
  @format_modules [
    slack_blocks: SlackBlocks,
    discord_embed: DiscordEmbed,
    pagerduty_v2: PagerdutyV2,
    json: Json,
    html: Html,
    markdown: Markdown,
    plain: Plain
  ]

  @formats Keyword.keys(@format_modules)
  @format_by_name Map.new(@formats, &{Atom.to_string(&1), &1})

  # The three action links carry a single-use capability token; `links.alert` is
  # a plain deep link and carries none. The `:stream` provider is exempt from
  # action links entirely (design D7), and dropping them here is what makes the
  # exemption hold for a hand-written template too.
  @action_link_names ~w(acknowledge snooze resolve)

  @expression_regex ~r/\{\{.*?\}\}/s
  @expression_body_regex ~r/\A\{\{(.*)\}\}\z/s
  @quoted_string_regex ~r/\A"((?:[^"\\]|\\.)*)"\z/

  # Below this length a "sensitive value" is more likely to be a substring of
  # ordinary text than a credential, and blanket-replacing it would corrupt the
  # redacted payload it is meant to protect.
  @min_sensitive_value_bytes 8

  @type payload_format ::
          :slack_blocks | :discord_embed | :markdown | :plain | :html | :pagerduty_v2 | :json

  @type template :: map() | struct()

  @type error ::
          {:missing_option, :supported_formats}
          | {:no_supported_payload_format, term()}
          | {:unknown_payload_format, term()}
          | {:unsupported_payload_format, %{requested: payload_format(), supported: [atom()]}}
          | {:template_format_mismatch, %{template: atom(), negotiated: payload_format()}}
          | {:missing_body_template, payload_format()}
          | {:invalid_template, %{field: atom(), message: String.t()}}
          | {:invalid_alert_snapshot, term()}

  defmodule Unresolved do
    @moduledoc """
    One `{{ ... }}` whose variable path produced nothing.

    `reason` distinguishes a path the context does not carry at all
    (`:missing` - usually a template written against the wrong alert class) from
    one that is present and nil (`:nil_value` - usually an alert that genuinely
    has no device). `default_applied?` records whether a `default:` filter
    supplied a substitute, which is the difference between a handled gap and a
    silent blank.
    """

    @enforce_keys [:path, :expression, :location, :reason]
    defstruct [:path, :expression, :location, :reason, default_applied?: false]

    @type t :: %__MODULE__{
            path: String.t(),
            expression: String.t(),
            location: :subject | :body,
            reason: :missing | :nil_value,
            default_applied?: boolean()
          }
  end

  defmodule Rendered do
    @moduledoc """
    The finished render.

    `payload` goes on the wire; `redacted_payload` and `digest` are the only
    forms that may be persisted or logged. `payload_format` and `provider_version`
    are copied onto the `NotificationDelivery` row before dispatch, so the row
    stays explicable after the provider's format list or definition version moves
    on (design G7/G8).
    """

    @enforce_keys [:payload_format, :payload, :redacted_payload, :body, :digest]

    defstruct [
      :payload_format,
      :payload,
      :redacted_payload,
      :subject,
      :body,
      :digest,
      :provider_version,
      :redaction_policy_version,
      unresolved: []
    ]

    @type t :: %__MODULE__{
            payload_format: ServiceRadar.Notifications.Renderer.payload_format(),
            payload: map(),
            redacted_payload: map(),
            subject: String.t() | nil,
            body: String.t(),
            digest: String.t() | nil,
            provider_version: pos_integer() | nil,
            redaction_policy_version: String.t(),
            unresolved: [ServiceRadar.Notifications.Renderer.Unresolved.t()]
          }

    @doc """
    True when some variable rendered empty and no `default:` covered it.

    A `default:`-covered gap is excluded on purpose: the operator declared what
    should appear, so it is not a defect to surface.
    """
    @spec unresolved?(t()) :: boolean()
    def unresolved?(%__MODULE__{unresolved: unresolved}) do
      Enum.any?(unresolved, &(&1.default_applied? == false))
    end

    @doc "The distinct unhandled variable paths, sorted."
    @spec unresolved_paths(t()) :: [String.t()]
    def unresolved_paths(%__MODULE__{unresolved: unresolved}) do
      unresolved
      |> Enum.reject(& &1.default_applied?)
      |> Enum.map(& &1.path)
      |> Enum.uniq()
      |> Enum.sort()
    end
  end

  @doc "Every payload format the platform renders, in negotiation-preference order."
  @spec payload_formats() :: [payload_format()]
  def payload_formats, do: @formats

  @doc """
  Resolves a payload format from an atom or a string, against a fixed map.

  Never `String.to_atom/1`: the value reaches here from a provider row an
  operator can edit.
  """
  @spec parse_format(term()) :: {:ok, payload_format()} | {:error, error()}
  def parse_format(format) when format in @formats, do: {:ok, format}

  def parse_format(format) when is_binary(format) do
    case Map.fetch(@format_by_name, format) do
      {:ok, parsed} -> {:ok, parsed}
      :error -> {:error, {:unknown_payload_format, format}}
    end
  end

  def parse_format(other), do: {:error, {:unknown_payload_format, other}}

  @doc "The module that renders a payload format."
  @spec format_module(payload_format()) :: {:ok, module()} | {:error, error()}
  def format_module(format) do
    case Keyword.fetch(@format_modules, format) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown_payload_format, format}}
    end
  end

  @doc """
  Picks the format to render, refusing any format the provider does not declare.

  With `requested` nil the richest declared format wins. With a `requested`
  format outside `supported`, the answer is
  `{:error, {:unsupported_payload_format, _}}` - never a substitution, because a
  destination handed the wrong shape answers 400 and a 400 is terminal.
  """
  @spec negotiate_format(term(), term()) :: {:ok, payload_format()} | {:error, error()}
  def negotiate_format(requested, supported) do
    with {:ok, declared} <- normalize_supported(supported) do
      do_negotiate(requested, declared)
    end
  end

  @doc """
  Renders one notification.

  `alert_snapshot` populates both the `alert.*` and `snapshot.*` variable
  namespaces. `template` is a resolved `NotificationTemplate` (or any map
  carrying `:subject_template`, `:body_template`, and optionally
  `:payload_format`). `target_format` may be nil, in which case the richest
  declared format is chosen.

  ## Options

    * `:supported_formats` - REQUIRED. The provider's declared `payload_formats`.
    * `:context` - the non-alert variable namespaces (`device`, `rule`, `route`,
      `policy`, `step`, `channel`, `provider`, `delivery`, `system`).
      `system.now` lives here; the renderer never reads the clock.
    * `:links` - `%{acknowledge:, snooze:, resolve:, alert:}`.
    * `:include_action_links?` - default true. Pass false for the `:stream`
      provider, which is exempt from action links (design D7); the three action
      links are then dropped from the variable context as well, so a hand-written
      template cannot reintroduce a capability token into a broadcast.
    * `:dedupe_key` - the delivery dedupe key. For `:pagerduty_v2` this becomes
      `dedup_key` and is what correlates a trigger with its later resolve.
    * `:event_action` - `:trigger` (default) or `:resolve`.
    * `:provider_version` - stamped onto the result for the delivery row.
    * `:sensitive_values` - strings to scrub from `redacted_payload`.
    * `:redaction_schema` - a JSON Schema passed to `ActionRedaction`.
    * `:timestamp`, `:source` - overrides for the corresponding payload fields.
  """
  @spec render(map(), template(), term(), keyword()) :: {:ok, Rendered.t()} | {:error, error()}
  def render(alert_snapshot, template, target_format \\ nil, opts \\ [])

  def render(alert_snapshot, template, target_format, opts) when is_map(alert_snapshot) do
    with {:ok, supported} <- fetch_supported(opts),
         {:ok, format} <- negotiate_format(target_format || template_format(template), supported),
         {:ok, module} <- format_module(format),
         :ok <- check_template_format(template, format),
         {:ok, body_template} <- fetch_body_template(template, format),
         subject_template = template_field(template, :subject_template),
         :ok <- validate_syntax(subject_template, :subject_template),
         :ok <- validate_syntax(body_template, :body_template) do
      context = build_context(alert_snapshot, opts)
      {subject, subject_unresolved} = substitute(subject_template, context, module, :subject)
      {body, body_unresolved} = substitute(body_template, context, module, :body)

      content = build_content(format, subject, body, alert_snapshot, context, opts)
      payload = module.render(content)
      {redacted, digest, policy_version} = finalize_payload(payload, opts)

      {:ok,
       %Rendered{
         payload_format: format,
         payload: payload,
         redacted_payload: redacted,
         subject: subject,
         body: body,
         digest: digest,
         provider_version: Keyword.get(opts, :provider_version),
         redaction_policy_version: policy_version,
         unresolved: subject_unresolved ++ body_unresolved
       }}
    end
  end

  def render(alert_snapshot, _template, _target_format, _opts) do
    {:error, {:invalid_alert_snapshot, alert_snapshot}}
  end

  @doc """
  Substitutes one template string, for previews and for tests of the filter set.

  Returns the rendered string and the list of unresolved expressions. `format`
  selects the escaping applied to substituted values.

  ## Options

    * `:field`, `:location` - what the resulting `Unresolved` entries name.
    * `:extra_paths` - additional exact variable paths this template may address,
      forwarded to `Syntax.validate_template/2`. It exists for the declarative
      provider tier, whose `config.*` and `secrets.*` leaves come from one
      provider document's own `config_schema`; pass
      `ServiceRadar.Notifications.Declarative.Definition.config_paths/1 ++
      secret_paths/1` and put the corresponding values in `context`. `render/4`
      deliberately does NOT accept it: a notification body is bound to the closed
      catalog.
  """
  @spec render_string(String.t() | nil, map(), payload_format(), keyword()) ::
          {:ok, String.t() | nil, [Unresolved.t()]} | {:error, error()}
  def render_string(template, context, format \\ :plain, opts \\ []) do
    with {:ok, module} <- format_module(format),
         :ok <-
           validate_syntax(
             template,
             Keyword.get(opts, :field, :body_template),
             Keyword.take(opts, [:extra_paths])
           ) do
      {rendered, unresolved} =
        substitute(
          template,
          normalize_context(context),
          module,
          Keyword.get(opts, :location, :body)
        )

      {:ok, rendered, unresolved}
    end
  end

  @doc "An operator-readable sentence for a render error."
  @spec describe_error(term()) :: String.t()
  def describe_error({:missing_option, :supported_formats}) do
    "the provider's declared payload_formats must be supplied; a channel is never " <>
      "asked for a format its provider does not declare"
  end

  def describe_error({:no_supported_payload_format, supported}) do
    "the provider declares no usable payload format (got #{inspect(supported)})"
  end

  def describe_error({:unknown_payload_format, value}) do
    "#{inspect(value)} is not a payload format; the set is #{inspect(@formats)}"
  end

  def describe_error({:unsupported_payload_format, %{requested: requested, supported: supported}}) do
    "this provider does not declare #{inspect(requested)}; it declares #{inspect(supported)}"
  end

  def describe_error({:template_format_mismatch, %{template: template, negotiated: negotiated}}) do
    "the resolved template renders #{inspect(template)} but #{inspect(negotiated)} was " <>
      "negotiated; resolve the template for the negotiated format"
  end

  def describe_error({:missing_body_template, format}) do
    "no body template resolved for #{inspect(format)}"
  end

  def describe_error({:invalid_template, %{field: field, message: message}}) do
    "#{field}: #{message}"
  end

  def describe_error(other), do: inspect(other)

  # --- format negotiation ---------------------------------------------------

  defp fetch_supported(opts) do
    case Keyword.fetch(opts, :supported_formats) do
      {:ok, supported} -> normalize_supported(supported)
      :error -> {:error, {:missing_option, :supported_formats}}
    end
  end

  defp normalize_supported(supported) when is_list(supported) and supported != [] do
    supported
    |> Enum.reduce_while({:ok, []}, fn format, {:ok, acc} ->
      case parse_format(format) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_supported(supported), do: {:error, {:no_supported_payload_format, supported}}

  defp do_negotiate(nil, declared) do
    case Enum.find(@formats, &(&1 in declared)) do
      nil -> {:error, {:no_supported_payload_format, declared}}
      format -> {:ok, format}
    end
  end

  defp do_negotiate(requested, declared) do
    with {:ok, format} <- parse_format(requested) do
      if format in declared do
        {:ok, format}
      else
        {:error, {:unsupported_payload_format, %{requested: format, supported: declared}}}
      end
    end
  end

  # --- template access ------------------------------------------------------

  defp template_format(template) do
    case template_field(template, :payload_format) do
      nil -> nil
      format -> format
    end
  end

  # A template is selected by (alert class x payload format); a template whose
  # declared format is not the negotiated one means the caller resolved the wrong
  # row, and rendering it anyway is how Markdown ends up inside a JSON field.
  defp check_template_format(template, negotiated) do
    case template_field(template, :payload_format) do
      nil ->
        :ok

      declared ->
        case parse_format(declared) do
          {:ok, ^negotiated} ->
            :ok

          {:ok, other} ->
            {:error, {:template_format_mismatch, %{template: other, negotiated: negotiated}}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp fetch_body_template(template, format) do
    case template_field(template, :body_template) do
      body when is_binary(body) -> {:ok, body}
      _other -> {:error, {:missing_body_template, format}}
    end
  end

  defp template_field(template, field) when is_struct(template) do
    Map.get(template, field)
  end

  defp template_field(template, field) when is_map(template) do
    case Map.fetch(template, field) do
      {:ok, value} -> value
      :error -> Map.get(template, Atom.to_string(field))
    end
  end

  defp template_field(_template, _field), do: nil

  defp validate_syntax(template, field, syntax_opts \\ [])

  defp validate_syntax(nil, _field, _syntax_opts), do: :ok

  defp validate_syntax(template, field, syntax_opts) do
    case Syntax.validate_template(template, syntax_opts) do
      :ok -> :ok
      {:error, message} -> {:error, {:invalid_template, %{field: field, message: message}}}
    end
  end

  # --- context --------------------------------------------------------------

  defp build_context(alert_snapshot, opts) do
    base = normalize_context(Keyword.get(opts, :context, %{}))

    links =
      opts
      |> Keyword.get(:links, Map.get(base, "links", %{}))
      |> normalize_links()
      |> filter_action_links(include_action_links?(opts))

    base
    |> Map.put("alert", alert_snapshot)
    |> Map.put("snapshot", alert_snapshot)
    |> Map.put("links", links)
  end

  defp normalize_context(context) when is_map(context) do
    Map.new(context, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_context(_context), do: %{}

  defp normalize_links(links) when is_map(links) do
    Map.new(links, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_links(_links), do: %{}

  defp filter_action_links(links, true), do: links
  defp filter_action_links(links, false), do: Map.drop(links, @action_link_names)

  defp include_action_links?(opts), do: Keyword.get(opts, :include_action_links?, true) != false

  defp build_content(format, subject, body, alert_snapshot, context, opts) do
    links = Map.get(context, "links", %{})

    %Content{
      payload_format: format,
      subject: Format.presence(subject),
      body: body || "",
      severity: string_field(alert_snapshot, "severity"),
      alert_class: string_field(alert_snapshot, "alert_class"),
      alert_id: string_field(alert_snapshot, "id"),
      alert_url: Content.link(links, :alert) || string_field(alert_snapshot, "url"),
      dedupe_key: opt_string(opts, :dedupe_key) || string_field(alert_snapshot, "dedupe_key"),
      source: opt_string(opts, :source) || string_field(alert_snapshot, "source"),
      timestamp: opt_string(opts, :timestamp) || timestamp_field(alert_snapshot),
      delivery_id: opt_string(opts, :delivery_id),
      snooze_seconds: snooze_seconds(opts),
      alert: alert_snapshot,
      links: links,
      include_action_links?: include_action_links?(opts),
      interactive?: Keyword.get(opts, :interactive?, false) == true,
      event_action: Keyword.get(opts, :event_action, :trigger)
    }
  end

  # The duration a Snooze control grants, taken from the SAME source the Phase 1
  # link path mints against (`ActionLinks.default_snooze_seconds/0`) rather than
  # restated here. Two ingresses to one mechanism disagreeing about how long
  # "Snooze 1h" is would be invisible until an operator compared a button with a
  # link.
  defp snooze_seconds(opts) do
    case Keyword.get(opts, :snooze_seconds, ActionLinks.default_snooze_seconds()) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _other -> ActionLinks.default_snooze_seconds()
    end
  end

  defp opt_string(opts, key) do
    case Keyword.get(opts, key) do
      nil -> nil
      value -> stringify(value)
    end
  end

  defp string_field(map, key) do
    case fetch_key(map, key) do
      {:ok, nil} -> nil
      {:ok, value} -> Format.presence(stringify(value))
      :error -> nil
    end
  end

  defp timestamp_field(alert_snapshot) do
    Enum.find_value(["first_seen_at", "last_seen_at", "timestamp"], fn key ->
      case fetch_key(alert_snapshot, key) do
        {:ok, nil} -> nil
        {:ok, value} -> Format.presence(iso8601(value))
        :error -> nil
      end
    end)
  end

  # --- substitution ---------------------------------------------------------

  defp substitute(nil, _context, _module, _location), do: {nil, []}

  defp substitute(template, context, module, location) when is_binary(template) do
    {parts, unresolved} =
      @expression_regex
      |> Regex.split(template, include_captures: true)
      |> Enum.reduce({[], []}, fn part, {parts, unresolved} ->
        case Regex.run(@expression_body_regex, part, capture: :all_but_first) do
          [body] ->
            {rendered, note} = evaluate(body, context, module, location)
            {[rendered | parts], prepend(note, unresolved)}

          nil ->
            {[part | parts], unresolved}
        end
      end)

    {parts |> Enum.reverse() |> IO.iodata_to_binary(), Enum.reverse(unresolved)}
  end

  defp prepend(nil, unresolved), do: unresolved
  defp prepend(note, unresolved), do: [note | unresolved]

  defp evaluate(body, context, module, location) do
    [path_segment | filter_segments] = split_pipeline(body)
    path = String.trim(path_segment)
    initial = resolve_path(context, path)
    {state, _defaulted?} = apply_filters(filter_segments, {initial, false})

    {module.escape(finalize(state)), note(initial, state, path, body, location)}
  end

  defp note({:resolved, _value}, _state, _path, _body, _location), do: nil

  defp note({:unresolved, reason}, state, path, body, location) do
    %Unresolved{
      path: path,
      expression: "{{" <> body <> "}}",
      location: location,
      reason: reason,
      default_applied?: match?({:resolved, _value}, state)
    }
  end

  defp finalize({:resolved, value}), do: stringify(value)
  defp finalize({:unresolved, _reason}), do: ""

  # --- variable resolution --------------------------------------------------

  defp resolve_path(context, path) do
    case fetch_in(context, String.split(path, ".")) do
      {:ok, nil} -> {:unresolved, :nil_value}
      {:ok, value} -> {:resolved, value}
      :error -> {:unresolved, :missing}
    end
  end

  defp fetch_in(value, []), do: {:ok, value}

  defp fetch_in(value, [segment | rest]) when is_map(value) do
    case fetch_key(value, segment) do
      {:ok, child} -> fetch_in(child, rest)
      :error -> :error
    end
  end

  defp fetch_in(_value, _segments), do: :error

  # String keys hit `Map.fetch/2`; atom keys are matched by comparing the atoms
  # already in the map, so no atom is ever created from operator input.
  defp fetch_key(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        Enum.reduce_while(map, :error, fn
          {candidate, value}, _acc when is_atom(candidate) ->
            if Atom.to_string(candidate) == key, do: {:halt, {:ok, value}}, else: {:cont, :error}

          _pair, acc ->
            {:cont, acc}
        end)
    end
  end

  defp fetch_key(_map, _key), do: :error

  # --- filters --------------------------------------------------------------

  defp apply_filters(segments, acc) do
    Enum.reduce(segments, acc, fn segment, {state, defaulted?} ->
      {name, argument} = parse_filter(segment)
      apply_filter(name, argument, state, defaulted?)
    end)
  end

  defp parse_filter(segment) do
    case String.split(segment, ":", parts: 2) do
      [name] -> {String.trim(name), nil}
      [name, argument] -> {String.trim(name), String.trim(argument)}
    end
  end

  defp apply_filter("default", argument, state, _defaulted?) do
    if needs_default?(state) do
      {{:resolved, literal(argument)}, true}
    else
      {state, false}
    end
  end

  defp apply_filter(_name, _argument, {:unresolved, _reason} = state, defaulted?) do
    {state, defaulted?}
  end

  defp apply_filter("upper", _argument, {:resolved, value}, defaulted?) do
    {{:resolved, String.upcase(stringify(value))}, defaulted?}
  end

  defp apply_filter("lower", _argument, {:resolved, value}, defaulted?) do
    {{:resolved, String.downcase(stringify(value))}, defaulted?}
  end

  defp apply_filter("truncate", argument, {:resolved, value}, defaulted?) do
    case Integer.parse(argument || "") do
      {limit, ""} when limit > 0 ->
        {{:resolved, Format.truncate(stringify(value), limit)}, defaulted?}

      _other ->
        {{:resolved, value}, defaulted?}
    end
  end

  defp apply_filter("json", _argument, {:resolved, value}, defaulted?) do
    {{:resolved, encode_json(value)}, defaulted?}
  end

  defp apply_filter("url_encode", _argument, {:resolved, value}, defaulted?) do
    {{:resolved, URI.encode_www_form(stringify(value))}, defaulted?}
  end

  defp apply_filter("iso8601", _argument, {:resolved, value}, defaulted?) do
    {{:resolved, iso8601(value)}, defaulted?}
  end

  # Unreachable for a saved template - `Syntax` rejects an unknown filter at save
  # time - but rendering must not raise on a row that predates a catalog change.
  defp apply_filter(_name, _argument, state, defaulted?), do: {state, defaulted?}

  defp needs_default?({:unresolved, _reason}), do: true
  defp needs_default?({:resolved, value}), do: Format.blank?(stringify(value))

  defp literal(nil), do: ""

  defp literal(argument) do
    case Regex.run(@quoted_string_regex, argument, capture: :all_but_first) do
      [inner] -> unescape(inner)
      nil -> argument
    end
  end

  defp unescape(value) do
    value
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end

  # --- coercion -------------------------------------------------------------

  defp stringify(nil), do: ""
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp stringify(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp stringify(%Date{} = value), do: Date.to_iso8601(value)
  defp stringify(%Time{} = value), do: Time.to_iso8601(value)
  defp stringify(%_struct{} = value), do: safe_to_string(value)
  defp stringify(value) when is_map(value) or is_list(value), do: encode_json(value)
  defp stringify(value), do: safe_to_string(value)

  defp safe_to_string(value) do
    to_string(value)
  rescue
    _error -> inspect(value)
  end

  defp encode_json(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> Jason.encode!(safe_to_string(value))
    end
  end

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp iso8601(%Date{} = value), do: Date.to_iso8601(value)
  defp iso8601(%Time{} = value), do: Time.to_iso8601(value)

  defp iso8601(value) when is_integer(value) do
    unit = if abs(value) > 100_000_000_000, do: :millisecond, else: :second

    case DateTime.from_unix(value, unit) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      {:error, _reason} -> to_string(value)
    end
  end

  defp iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        DateTime.to_iso8601(datetime)

      {:error, _reason} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} -> NaiveDateTime.to_iso8601(naive)
          {:error, _naive_reason} -> value
        end
    end
  end

  defp iso8601(value), do: stringify(value)

  # --- redaction ------------------------------------------------------------

  defp finalize_payload(payload, opts) do
    schema = Keyword.get(opts, :redaction_schema)
    sensitive = sensitive_values(opts)

    scrubbed =
      payload
      |> ActionRedaction.redact(schema)
      |> scrub(sensitive)

    # `for_storage/2` is idempotent over an already-redacted term (redaction
    # matches on key names, which the first pass did not change) and gives the
    # canonical, key-order-independent sha256 plus the policy version, so the
    # digest is computed exactly the way every other persisted redacted value in
    # the platform is.
    storage = ActionRedaction.for_storage(scrubbed, schema)

    {storage.redacted, storage.sha256, storage.policy_version}
  end

  defp sensitive_values(opts) do
    opts
    |> Keyword.get(:sensitive_values, [])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= @min_sensitive_value_bytes))
    |> Enum.uniq()
  end

  defp scrub(value, []), do: value

  defp scrub(value, sensitive) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, child} -> {key, scrub(child, sensitive)} end)
  end

  defp scrub(value, sensitive) when is_list(value) do
    Enum.map(value, &scrub(&1, sensitive))
  end

  defp scrub(value, sensitive) when is_binary(value) do
    Enum.reduce(sensitive, value, &String.replace(&2, &1, "[REDACTED]"))
  end

  defp scrub(value, _sensitive), do: value

  # --- pipeline splitting ---------------------------------------------------
  #
  # Splits on `|` while respecting double-quoted filter arguments so that
  # `default: "a|b"` stays one segment. The grammar is owned by
  # `Template.Syntax`, which has already rejected anything malformed by the time
  # a string reaches here; this is the evaluation-side reader of the same shape.

  defp split_pipeline(body), do: do_split(body, [], "", false)

  defp do_split(<<>>, acc, current, _in_string?), do: Enum.reverse([current | acc])

  defp do_split(<<?\\, next::utf8, rest::binary>>, acc, current, true) do
    do_split(rest, acc, current <> <<?\\>> <> <<next::utf8>>, true)
  end

  defp do_split(<<?", rest::binary>>, acc, current, in_string?) do
    do_split(rest, acc, current <> "\"", not in_string?)
  end

  defp do_split(<<?|, rest::binary>>, acc, current, false) do
    do_split(rest, [current | acc], "", false)
  end

  defp do_split(<<char::utf8, rest::binary>>, acc, current, in_string?) do
    do_split(rest, acc, current <> <<char::utf8>>, in_string?)
  end
end
