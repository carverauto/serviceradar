defmodule ServiceRadar.Notifications.Transports.Declarative do
  @moduledoc """
  The execution engine for the `:declarative` provider tier: render one
  operator-supplied request-template document and issue it (tasks 2.2.1-2.2.4).

  Design D2 puts roughly 85% of notification destinations in one sentence -
  "POST this JSON body to this URL with these headers" - and this module is the
  half of that sentence the platform executes. `Declarative.Definition` decides
  whether a document is admissible; this decides what one delivery of it looks
  like on the wire. **An operator adds a provider by uploading a document: no
  code, no release, no Wasm toolchain**, and the only reason that claim holds is
  that nothing here is per-provider.

  ## It is a transport like any other

  It implements `ServiceRadar.Notifications.Transport` - `deliver/2`,
  `validate_config/1`, `capabilities/0`, `test/2` - so routing, escalation,
  deduplication, suppression, and acknowledgement cannot tell a Mattermost
  channel backed by an uploaded document from the `:native` Slack transport. The
  tier is resolved exactly once, when the dispatcher picks a module, and the
  `Result` this module returns says the same three things every other transport's
  does.

  ## What it does, in order

  | Step | Owner | Why not here |
  | --- | --- | --- |
  | Validate the document | `Declarative.Definition` | The document is validated at save time; a definition is DATA and re-deciding its shape per delivery is a second opinion |
  | Resolve the credential | `Credentials.SecretBroker`, via the dispatcher | A transport is a pure function of its request; a broker outage produces one classified failure, not N |
  | Substitute templates | `Notifications.Renderer` + `Template.Syntax` | There is exactly one restricted substitution engine (design D9) and this is not a second one |
  | Guard the URL | `Transports.HTTP` | The policy runs inside the one outbound path, before a socket exists |
  | Decide the retry rule | `Transport.Result.outcome/2` | C7 lives in one function |

  What is genuinely this module's own: turning `config` and `secrets` into the
  two template namespaces the document addresses, rendering the request the
  document describes, and mapping the answer through the document's own
  `success` / `failure` sets.

  ## Where the definition comes from

  `Transport.Request` carries a rendered notification, not a provider, so the
  document travels beside it. In production that is `Notifications.Dispatcher`,
  which puts the provider's `definition` and the variable context the body was
  rendered against on `request.metadata` - passing data the transport may use
  rather than branching on `provider_type`, which design D2 forbids downstream of
  the one module lookup. Both sources are read, in this order:

    * `opts[:definition]` - either an already-parsed
      `%Declarative.Definition{}` or the raw `NotificationProvider.definition`
      document. A caller that already holds the parsed struct passes it here.
    * `request.metadata["definition"]` - the same value, from the dispatcher.

  A raw document is parsed with `Declarative.Definition.parse/1` on the way in,
  which is what keeps a stored document that no longer validates from
  delivering. Pass the parsed struct to skip that work on a retry.

  ## Substitution, and what an unresolved variable means

  Every template is rendered by `Notifications.Renderer.render_string/4` with
  `extra_paths: config_paths(definition) ++ secret_paths(definition)` - the same
  catalog, the same seven filters, and the same two extra namespaces the
  validator enforced. No second engine, no EEx, no `Code.eval`.

  Values are substituted unescaped (`:plain`). That is deliberate in both
  directions: a `json` body is a document whose leaves are strings, and `Req`
  encodes it, so escaping here would double-encode; a URL that needs escaping
  says so with the published `url_encode` filter.

  An unresolved variable is not one condition but three, and they get three
  answers:

    * `config.*` or `secrets.*` - the channel is misconfigured, or its secret ref
      resolved to nothing. **Permanent failure, no request.** Sending a request
      with a hole where the token goes would spend the retry budget on a 401.
    * anywhere in `url` - a URL with a hole is a different URL. **Permanent
      failure, no request.**
    * anything else (`alert.*`, `device.*`, ...) - renders empty and is recorded
      in `result_summary["unresolved"]`, exactly as a notification body does. An
      alert genuinely may not carry a device, and dropping a page over it is the
      failure the whole platform exists to prevent.

  A `default:` filter that supplied a substitute is not a gap; it is the operator
  saying what should appear.

  ## Response classification is the document's decision, not the tier's

  `Definition.classify_status/2` answers `:success`, `:retryable`, or
  `:permanent` from the document's own sets, and everything the document lists in
  neither is terminal, per the spec. **A 200 that the document does not list as a
  success is a permanent failure** - some destinations answer 200 with an error
  body, and recording that as `:sent` is the silent failure this platform exists
  to prevent.

  The success case goes through `Transport.result_from_http_status/2`, which is
  where "a 2xx is a delivery" lives (`success.status` is 2xx-only by
  construction). The retry rule itself is never re-derived: this module returns a
  disposition and `Result.outcome/2` maps it.

  `failure.retry_after_header` is honoured on a retryable answer - the document
  names the header because `Retry-After` is not universal - and clamped to one
  hour, because a hostile or buggy hint must not park a delivery indefinitely.
  Only a delta-seconds value is read; an HTTP-date is ignored rather than
  guessed, matching `Transports.HTTP`.

  ## Secrets

  The dispatcher resolves `NotificationChannel.secret_refs` through
  `ServiceRadar.Credentials.SecretBroker` and hands the values over as
  `Request.secrets`; this module never calls the broker. Secrets are injected at
  request construction only - into the URL, a header, or the body, wherever the
  document's `secrets.*` reference sits - and every resolved value is passed to
  `Transports.HTTP` as `:sensitive_values`, so a token cannot survive into an
  error message, a `result_summary`, or a log line. `config` is not a sensitive
  column and holds no credential: the two namespaces are disjoint, which the
  document validator enforces.

  ## Testing seam

  `opts[:req_options]` is forwarded to `Transports.HTTP` and is how a test injects
  `plug:` or `adapter:`. Nothing here reaches the network in a test, and
  `render_request/2` renders without issuing anything at all - it is what the
  upload UI previews.

  See `openspec/changes/add-notification-platform/design.md` (D2, D9, Security)
  and the `notification-providers` spec, "Declarative Provider Request Template
  Document".
  """

  @behaviour ServiceRadar.Notifications.Transport

  alias ServiceRadar.Automation.Northbound.ActionRedaction
  alias ServiceRadar.Notifications.Declarative.Definition
  alias ServiceRadar.Notifications.Renderer
  alias ServiceRadar.Notifications.Transport
  alias ServiceRadar.Notifications.Transport.Request
  alias ServiceRadar.Notifications.Transport.Result
  alias ServiceRadar.Notifications.Transports.HTTP
  alias ServiceRadar.Plugins.ConfigSchema
  alias ServiceRadar.Plugins.SecretRefs

  require Logger

  # Same clamp as `Transports.HTTP` applies to `Retry-After`: the scheduler is
  # bounded by `max_attempts` anyway, so a far-future hint is clamped rather than
  # trusted.
  @max_retry_after_ms 3_600_000

  # Enough of a rejection body to identify it, short enough that it cannot become
  # a log-sized payload copy.
  @max_error_body_bytes 512

  # `result_summary` is persisted on the delivery row. The unresolved list is
  # diagnostic, so it is capped rather than allowed to grow with the document.
  @max_reported_unresolved 20

  # The two namespaces whose gaps are a configuration defect rather than an
  # absent alert field.
  @configuration_prefixes ["config.", "secrets."]

  @type rendered_request :: %{
          method: Definition.Request.method(),
          url: String.t(),
          headers: %{optional(String.t()) => String.t()},
          body_format: Definition.Request.body_format(),
          body: term(),
          unresolved: [String.t()]
        }

  # --- callbacks ------------------------------------------------------------

  @impl true
  @doc """
  What a request-template engine can do.

  Identical to `Declarative.Definition.allowed_capabilities/0`, because a
  document may declare only what this module can honour: there is no thread
  state, no inbound endpoint, and no second request template here.
  """
  @spec capabilities() :: [Transport.capability()]
  def capabilities, do: Definition.allowed_capabilities()

  @impl true
  @spec validate_config(term()) :: :ok | {:error, [Transport.config_error()]}
  def validate_config(config), do: validate_config(config, [])

  @doc """
  Checks a channel's configuration against the definition's `config_schema`.

  The definition is REQUIRED and is passed as `opts[:definition]`: unlike the
  four `:native` transports, this module has no compile-time contract of its own
  to check against, and answering `:ok` for a configuration nothing examined
  would be a save-time check that silently did nothing. `validate_config/1` is
  the behaviour callback and reports the missing option rather than passing.

  Only the non-secret properties are checked here. A `secretRef: true` property's
  value lives in `NotificationChannel.secret_refs`, not in `config`, so requiring
  it of the config map would reject every correctly configured channel;
  `Notifications.Changes.ApplyProviderContract` validates the two halves together
  where it can see both.
  """
  @spec validate_config(term(), keyword()) :: :ok | {:error, [Transport.config_error()]}
  def validate_config(config, opts) when is_list(opts) do
    with {:ok, definition} <- required_definition(opts),
         {:ok, normalized} <- configuration_map(config) do
      schema_errors(definition, normalized)
    end
  end

  @impl true
  @spec deliver(Request.t() | term(), keyword()) :: Result.t()
  def deliver(%Request{} = request, opts) when is_list(opts) do
    sensitive = sensitive_values(request, opts)

    with {:ok, definition} <- request_definition(request, opts),
         {:ok, rendered} <- build_request(definition, context(request, opts)) do
      definition
      |> issue(rendered, sensitive, opts)
      |> log_failure(request, sensitive)
    else
      {:error, error_class, errors} -> refuse(error_class, errors, request, sensitive)
    end
  rescue
    exception -> unexpected(exception, __STACKTRACE__, request)
  catch
    :exit, reason -> unexpected_exit(reason, request)
  end

  def deliver(request, _opts) do
    Result.permanent_failure("invalid_request",
      error_message: "expected a Transport.Request, got #{inspect(request)}"
    )
  end

  @impl true
  @doc """
  Test send.

  Deliberately `deliver/2` itself. A test that rendered a fixed body, skipped the
  URL guard, or used anything other than the channel's real configuration and
  resolved secrets would not be evidence that the channel works (design D2). The
  delivery it produces carries `is_test: true`, so the engine already excludes it
  from every count - no alert is created and nothing is escalated.
  """
  @spec test(Request.t(), keyword()) :: Result.t()
  def test(request, opts), do: deliver(request, opts)

  # --- rendering ------------------------------------------------------------

  @doc """
  Renders the request a definition describes, without issuing it.

  `context` is the variable context: the notification namespaces (`alert`,
  `device`, `links`, ...) plus `"config"` and `"secrets"`. This is what the
  upload UI previews, and it is the same function `deliver/2` renders with, so a
  preview cannot disagree with what would be sent.

  Returns `{:error, errors}` for a configuration gap the request could not be
  built around; see the moduledoc for which gaps are refused and which render
  empty.
  """
  @spec render_request(Definition.t(), map()) ::
          {:ok, rendered_request()} | {:error, [Transport.config_error()]}
  def render_request(%Definition{} = definition, context) when is_map(context) do
    case build_request(definition, context) do
      {:ok, rendered} -> {:ok, rendered}
      {:error, _error_class, errors} -> {:error, errors}
    end
  end

  defp build_request(%Definition{request: template} = definition, context) do
    extra = Definition.config_paths(definition) ++ Definition.secret_paths(definition)

    with {:ok, url, url_gaps} <- render_one(template.url, context, extra, "request.url"),
         {:ok, headers, header_gaps} <- render_headers(template.headers, context, extra),
         {:ok, body, body_gaps} <-
           render_body(template.body_format, template.body, context, extra),
         gaps = url_gaps ++ header_gaps ++ body_gaps,
         :ok <- check_gaps(gaps),
         :ok <- check_url(url) do
      {:ok,
       %{
         method: template.method,
         url: url,
         headers: headers,
         body_format: template.body_format,
         body: body,
         unresolved: reported_gaps(gaps)
       }}
    end
  end

  # One template. `:plain` escaping, because the document's filters are the
  # published way to escape a value and the transport encodes the body itself.
  defp render_one(template, context, extra, path) do
    case Renderer.render_string(template, context, :plain, extra_paths: extra) do
      {:ok, rendered, unresolved} ->
        {:ok, rendered || "", gaps(unresolved, path)}

      {:error, reason} ->
        # Unreachable for a parsed definition - the same validator ran over the
        # same template with the same extra paths - but a document that reaches
        # here another way must produce a readable row, not a MatchError.
        {:error, "invalid_definition",
         [%{field: path, message: "is not renderable: " <> Renderer.describe_error(reason)}]}
    end
  end

  # A `default:` filter that supplied a substitute is the operator saying what
  # should appear, so it is not a gap.
  defp gaps(unresolved, path) do
    unresolved
    |> Enum.reject(& &1.default_applied?)
    |> Enum.map(&%{document_path: path, variable: &1.path})
  end

  defp render_headers(headers, context, extra) do
    headers
    |> Enum.sort_by(fn {name, _template} -> name end)
    |> Enum.reduce_while({:ok, %{}, []}, fn {name, template}, {:ok, acc, gaps} ->
      case render_one(template, context, extra, "request.headers." <> name) do
        {:ok, value, new_gaps} ->
          {:cont, {:ok, Map.put(acc, name, header_value(value)), gaps ++ new_gaps}}

        error ->
          {:halt, error}
      end
    end)
  end

  # A substituted value can carry a newline even though the template could not:
  # an alert title is operator-adjacent data and "title\r\nX-Evil: 1" is header
  # injection. Collapsing the line breaks keeps the header readable and keeps the
  # notification moving; refusing the delivery would let any alert text take a
  # channel down.
  defp header_value(value) do
    value
    |> String.replace(["\r\n", "\r", "\n"], " ")
    |> String.trim()
  end

  defp render_body(:text, body, context, extra) do
    render_one(body, context, extra, "request.body")
  end

  defp render_body(:form, body, context, extra) do
    body
    |> Enum.sort_by(fn {name, _value} -> name end)
    |> Enum.reduce_while({:ok, %{}, []}, fn {name, value}, {:ok, acc, gaps} ->
      case render_form_value(value, context, extra, join("request.body", name)) do
        {:ok, rendered, new_gaps} ->
          {:cont, {:ok, Map.put(acc, name, rendered), gaps ++ new_gaps}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp render_body(:json, body, context, extra) do
    render_json(body, context, extra, "request.body", [])
  end

  defp render_form_value(value, context, extra, path) when is_binary(value) do
    render_one(value, context, extra, path)
  end

  # A form body is a flat map of strings on the wire; the document may write a
  # number or a boolean, and it means the obvious thing.
  defp render_form_value(value, _context, _extra, _path), do: {:ok, to_string(value), []}

  defp render_json(value, context, extra, path, gaps) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _child} -> key end)
    |> Enum.reduce_while({:ok, %{}, gaps}, fn {key, child}, {:ok, acc, gaps} ->
      case render_json(child, context, extra, join(path, key), gaps) do
        {:ok, rendered, gaps} -> {:cont, {:ok, Map.put(acc, key, rendered), gaps}}
        error -> {:halt, error}
      end
    end)
  end

  defp render_json(value, context, extra, path, gaps) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], gaps}, fn {child, index}, {:ok, acc, gaps} ->
      case render_json(child, context, extra, "#{path}[#{index}]", gaps) do
        {:ok, rendered, gaps} -> {:cont, {:ok, acc ++ [rendered], gaps}}
        error -> {:halt, error}
      end
    end)
  end

  defp render_json(value, context, extra, path, gaps) when is_binary(value) do
    case render_one(value, context, extra, path) do
      {:ok, rendered, new_gaps} -> {:ok, rendered, gaps ++ new_gaps}
      error -> error
    end
  end

  # A number, a boolean, or null is already the JSON value the author drew.
  defp render_json(value, _context, _extra, _path, gaps), do: {:ok, value, gaps}

  # --- gaps and the rendered URL --------------------------------------------

  defp check_gaps(gaps) do
    case Enum.split_with(gaps, &configuration_gap?/1) do
      {[], []} ->
        :ok

      {[], other} ->
        case Enum.filter(other, &(&1.document_path == "request.url")) do
          [] -> :ok
          url_gaps -> {:error, "invalid_url", Enum.map(url_gaps, &url_gap_error/1)}
        end

      {configuration, _other} ->
        {:error, "invalid_config", Enum.map(configuration, &configuration_gap_error/1)}
    end
  end

  defp configuration_gap?(%{variable: variable}) do
    Enum.any?(@configuration_prefixes, &String.starts_with?(variable, &1))
  end

  defp configuration_gap_error(%{document_path: path, variable: variable}) do
    %{
      field: field_for(variable),
      message:
        "#{path} substitutes {{ #{variable} }}, which this channel does not supply. " <>
          "Set it on the channel before sending; a request with a hole where a credential " <>
          "or a configured value belongs would be rejected by the destination."
    }
  end

  defp url_gap_error(%{variable: variable}) do
    %{
      field: "request.url",
      message:
        "substitutes {{ #{variable} }}, which resolved to nothing. A URL with a hole in it " <>
          "is a different URL, so no request was sent. Supply the value, or give the " <>
          "expression a default."
    }
  end

  # `secrets.token` is `secret_refs.token` on the channel; `config.x` is
  # `config.x`. Naming the column an operator edits is the difference between a
  # message they can act on and one they have to decode.
  defp field_for("secrets." <> name), do: "secret_refs." <> name
  defp field_for(variable), do: variable

  # The URL is guarded by `Transports.HTTP` before a socket exists, and this is
  # not a second guard: whitespace survives `URI.parse/1` and the outbound policy
  # both, and would come back from the client as an unclassified transport error
  # that costs the whole retry budget. A template that dropped an alert title
  # into a path without `| url_encode` is a permanent configuration defect and
  # says so.
  defp check_url(url) do
    cond do
      String.trim(url) == "" ->
        {:error, "invalid_url",
         [%{field: "request.url", message: "rendered empty, so no request was sent"}]}

      String.match?(url, ~r/[\s\x00-\x1f\x7f]/) ->
        {:error, "invalid_url",
         [
           %{
             field: "request.url",
             message:
               "rendered with whitespace or a control character in it, which is not a URL. " <>
                 "Percent-encode the substituted value with the url_encode filter."
           }
         ]}

      true ->
        :ok
    end
  end

  defp reported_gaps(gaps) do
    gaps
    |> Enum.map(& &1.variable)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(@max_reported_unresolved)
  end

  # --- the request ----------------------------------------------------------

  defp issue(definition, rendered, sensitive, opts) do
    http_opts = [
      headers: rendered.headers,
      content_type: rendered.body_format,
      timeout_ms: definition.timeout_ms,
      sensitive_values: sensitive,
      req_options: Keyword.get(opts, :req_options, [])
    ]

    rendered.method
    |> HTTP.request(rendered.url, rendered.body, http_opts)
    |> to_result(definition, rendered, sensitive)
  end

  defp to_result({:ok, %{status: status} = response}, definition, rendered, sensitive) do
    summary = result_summary(rendered, status)

    case Definition.classify_status(definition, status) do
      :success ->
        # `success.status` is 2xx-only by construction, so this is
        # `Result.delivered/1` - reached through the one function that decides
        # what a status means rather than around it.
        Transport.result_from_http_status(status,
          external_correlation_id: Definition.extract_correlation_id(definition, response),
          result_summary: summary
        )

      :retryable ->
        Result.retryable_failure("http_#{status}",
          error_message: error_message(response, status, sensitive),
          retry_after_ms: retry_after_ms(definition, response),
          result_summary: summary
        )

      :permanent ->
        Result.permanent_failure("http_#{status}",
          error_message: error_message(response, status, sensitive) <> permanent_hint(status),
          result_summary: summary
        )
    end
  end

  # No status came back, so the document has nothing to say about it. A timeout,
  # a reset, and a blocked URL mean the same thing here as they do for every
  # native transport, and `Transports.HTTP` already decides them.
  defp to_result(outcome, _definition, rendered, sensitive) do
    HTTP.to_result(outcome,
      sensitive_values: sensitive,
      result_summary: result_summary(rendered, nil)
    )
  end

  # A 2xx the document did not list is the case an operator will not expect, so
  # the message says what happened rather than only what the status was.
  defp permanent_hint(status) when status >= 200 and status < 300 do
    ". The destination answered #{status}, which this provider's definition does not " <>
      "list in success.status, so the payload was not treated as delivered."
  end

  defp permanent_hint(_status), do: ""

  # `result_summary` is persisted on the delivery row and read in the Delivery
  # Log, so it carries only what happened: the status when there was one, and the
  # variables that rendered empty when there were any.
  defp result_summary(rendered, status) do
    summary = if is_nil(status), do: %{}, else: %{"http_status" => status}

    case rendered.unresolved do
      [] -> summary
      unresolved -> Map.put(summary, "unresolved", unresolved)
    end
  end

  # Only delta-seconds is read. An HTTP-date is a legal `Retry-After` and is
  # ignored rather than guessed at, which is what `Transports.HTTP` does for the
  # standard header; the scheduler's own backoff covers the case.
  defp retry_after_ms(definition, response) do
    with value when is_binary(value) <- HTTP.header(response, definition.retry_after_header),
         {seconds, _rest} <- Integer.parse(String.trim(value)),
         true <- seconds >= 0 do
      min(seconds * 1000, @max_retry_after_ms)
    else
      _other -> nil
    end
  end

  defp error_message(response, status, sensitive) do
    case summarize_body(response.body) do
      "" -> HTTP.scrub("HTTP #{status}", sensitive)
      summary -> HTTP.scrub("HTTP #{status}: #{summary}", sensitive)
    end
  end

  defp summarize_body(body) when is_binary(body), do: truncate(body)

  defp summarize_body(body) when is_map(body) or is_list(body) do
    case Jason.encode(body) do
      {:ok, encoded} -> truncate(encoded)
      {:error, _reason} -> truncate(inspect(body))
    end
  end

  defp summarize_body(nil), do: ""
  defp summarize_body(body), do: truncate(inspect(body))

  defp truncate(value) do
    trimmed = String.trim(value)

    if byte_size(trimmed) > @max_error_body_bytes do
      binary_part(trimmed, 0, @max_error_body_bytes) <> "..."
    else
      trimmed
    end
  end

  # --- the definition and the variable context ------------------------------

  defp request_definition(request, opts) do
    case Keyword.get(opts, :definition) || metadata(request, "definition") do
      nil ->
        {:error, "missing_definition",
         [
           %{
             field: nil,
             message:
               "this channel's provider definition was not supplied to the transport; a " <>
                 "declarative provider is its document, so there is nothing to send without it"
           }
         ]}

      definition ->
        parse_definition(definition)
    end
  end

  defp parse_definition(%Definition{} = definition), do: {:ok, definition}

  # Parsing per delivery is the price of the guarantee that a stored document
  # which no longer validates cannot deliver. A caller holding the parsed struct
  # (a retry, a batch) passes it instead and pays nothing.
  defp parse_definition(document) do
    case Definition.parse(document) do
      {:ok, definition} ->
        {:ok, definition}

      {:error, errors} ->
        {:error, "invalid_definition",
         [
           %{
             field: "definition",
             message:
               "this provider's definition is not a valid declarative document: " <>
                 Definition.describe_errors(errors)
           }
         ]}
    end
  end

  @doc """
  The variable context one delivery renders against.

  The notification namespaces come from the dispatcher (`opts[:context]`, or
  `request.metadata["template_context"]`), because only it has the alert
  snapshot and the minted action links. `config` and `secrets` are always taken
  from the request itself, so a supplied context cannot spoof either.

  With no context supplied, the namespaces the request itself can answer are
  still populated, which keeps a document addressing `delivery.id` or
  `channel.id` working in a caller that has nothing else.
  """
  @spec context(Request.t(), keyword()) :: map()
  def context(%Request{} = request, opts \\ []) do
    supplied =
      normalize_map(Keyword.get(opts, :context) || metadata(request, "template_context"))

    request
    |> request_context()
    |> Map.merge(supplied)
    |> Map.put("config", normalize_map(request.config))
    |> Map.put("secrets", normalize_map(request.secrets))
  end

  defp request_context(request) do
    %{
      "alert" => %{"id" => request.alert_id},
      "channel" => %{
        "id" => request.channel_id,
        "execution_route" => to_string(request.execution_route)
      },
      "provider" => %{"key" => request.provider_key},
      "delivery" => %{
        "id" => request.delivery_id,
        "max_attempts" => request.max_attempts,
        "dedupe_key" => request.dedupe_key,
        "payload_format" => to_string(request.payload_format),
        "external_correlation_id" => request.external_correlation_id
      }
    }
  end

  # --- validate_config ------------------------------------------------------

  defp required_definition(opts) do
    case Keyword.get(opts, :definition) do
      nil ->
        {:error,
         [
           %{
             field: nil,
             message:
               "a declarative channel is validated against its provider's definition; call " <>
                 "validate_config/2 with definition: the provider's document"
           }
         ]}

      definition ->
        case parse_definition(definition) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, _error_class, errors} -> {:error, errors}
        end
    end
  end

  defp configuration_map(config) when is_map(config) and not is_struct(config) do
    {:ok, normalize_map(config)}
  end

  defp configuration_map(config) do
    {:error, [%{field: nil, message: "expected a configuration map, got #{inspect(config)}"}]}
  end

  defp schema_errors(definition, config) do
    case ConfigSchema.validate_params(channel_schema(definition), config) do
      :ok -> :ok
      {:error, messages} -> {:error, Enum.map(messages, &%{field: "config", message: &1})}
    end
  end

  # The channel's `config` column holds the non-secret half of the document's
  # `config_schema`. The `secretRef: true` properties are references stored on
  # `secret_refs`, so they are dropped from both `properties` and `required`
  # before validating - keeping them would reject every correctly configured
  # channel for "missing" a field that is deliberately not there.
  defp channel_schema(%Definition{config_schema: schema}) do
    secret_fields = SecretRefs.secret_ref_fields(schema)

    schema
    |> update_map("properties", &Map.drop(&1, secret_fields))
    |> update_list("required", &Enum.reject(&1, fn name -> name in secret_fields end))
  end

  defp update_map(schema, key, fun) do
    case Map.get(schema, key) do
      value when is_map(value) and not is_struct(value) -> Map.put(schema, key, fun.(value))
      _other -> schema
    end
  end

  # An empty `required` is not a JSON Schema that means "require nothing"; it is
  # a schema draft 4 refuses. A document all of whose required fields are secret
  # refs produces exactly that, so the key goes rather than the list emptying.
  defp update_list(schema, key, fun) do
    case Map.get(schema, key) do
      value when is_list(value) ->
        case fun.(value) do
          [] -> Map.delete(schema, key)
          kept -> Map.put(schema, key, kept)
        end

      _other ->
        schema
    end
  end

  # --- failures -------------------------------------------------------------

  defp refuse(error_class, errors, request, sensitive) do
    result =
      Result.permanent_failure(error_class,
        error_message: HTTP.scrub(describe_errors(errors), sensitive),
        result_summary: %{"config_errors" => Enum.map(errors, & &1.field)}
      )

    log_failure(result, request, sensitive)
  end

  defp describe_errors(errors) do
    Enum.map_join(errors, "; ", fn
      %{field: nil, message: message} -> message
      %{field: field, message: message} -> "#{field} #{message}"
    end)
  end

  # A transport must never take the dispatcher down (design D2). Anything that
  # escapes the normal paths becomes a retryable failure with the delivery id
  # attached, which is a row an operator can read rather than an Oban stack
  # trace.
  defp unexpected(exception, stacktrace, request) do
    Logger.error(
      "declarative transport crashed delivery=#{inspect(delivery_id(request))} " <>
        Exception.format(:error, exception, stacktrace)
    )

    Result.retryable_failure("transport_exception",
      error_message: "the declarative transport raised #{inspect(exception.__struct__)}"
    )
  end

  defp unexpected_exit(reason, request) do
    Logger.error(
      "declarative transport exited delivery=#{inspect(delivery_id(request))} " <>
        inspect(reason)
    )

    Result.retryable_failure("transport_exit",
      error_message: "the declarative transport exited before the request completed"
    )
  end

  defp log_failure(%Result{disposition: :delivered} = result, _request, _sensitive), do: result

  defp log_failure(%Result{} = result, request, sensitive) do
    context =
      %{
        "delivery_id" => delivery_id(request),
        "channel_id" => Map.get(request, :channel_id),
        "provider_key" => Map.get(request, :provider_key),
        "error_class" => result.error_class,
        "error_message" => result.error_message
      }
      |> ActionRedaction.redact()
      |> HTTP.scrub(sensitive)

    Logger.warning("declarative provider delivery failed: #{inspect(context)}")

    result
  end

  defp delivery_id(%Request{delivery_id: delivery_id}), do: delivery_id
  defp delivery_id(_request), do: nil

  # --- map access -----------------------------------------------------------

  defp sensitive_values(request, opts) do
    secret_values = request.secrets |> normalize_map() |> Map.values()

    (secret_values ++ List.wrap(Keyword.get(opts, :sensitive_values, [])))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp metadata(%Request{metadata: metadata}, key) when is_map(metadata) do
    case Map.fetch(metadata, key) do
      {:ok, value} -> value
      :error -> Map.get(normalize_map(metadata), key)
    end
  end

  defp metadata(_request, _key), do: nil

  # Atom keys are matched by comparing atoms already present in the map, so no
  # atom is created from operator input (Iron Laws).
  defp normalize_map(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp normalize_map(_map), do: %{}

  defp join(path, key), do: path <> "." <> key
end
