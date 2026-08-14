defmodule ServiceRadar.Notifications.Declarative.Definition do
  @moduledoc """
  The declarative provider document: its shape, and the strict validator that
  decides whether an operator-supplied one is admissible (tasks 2.1.1-2.1.4).

  Design D2 puts roughly 85% of notification destinations in one sentence: "POST
  this JSON body to this URL with these headers". Alertmanager and Grafana both
  hardcoded their receiver list and cannot accept a community receiver without a
  release. The declarative tier is the answer to that, and the claim it makes is
  specific: **an operator adds a provider by uploading a document - no code, no
  release, no Wasm toolchain.** This module is the document's contract. Nothing
  in it is executable. A definition is DATA.

  ## The document

      schema_version: 1
      key: mattermost
      display_name: Mattermost
      description: Post alerts into a Mattermost channel via an incoming webhook.
      capabilities: [send, test]
      payload_formats: [markdown, json]
      routes: [control_plane]
      config_schema:
        type: object
        properties:
          webhook_url:
            type: string
            title: Webhook URL
            secretRef: true
            credentialKind: api_token
          username:
            type: string
            title: Override username
        required: [webhook_url]
      request:
        method: POST
        url: "{{ secrets.webhook_url }}"
        headers:
          Content-Type: application/json
        body_format: json
        body:
          text: "**{{ alert.severity | upper }}** {{ alert.title }}"
          username: "{{ config.username | default: \\"ServiceRadar\\" }}"
      success:
        status: [200, 204]
      failure:
        retryable_status: [429, "500-599"]
        retry_after_header: Retry-After
      response:
        external_correlation_id:
          from: body
          path: id

  Required: `schema_version`, `key`, `display_name`, `capabilities`,
  `payload_formats`, `config_schema`, `request`, `success`, `failure`.
  Optional: `description`, `icon`, `routes` (default `[control_plane]`),
  `timeout_ms`, `response`.

  ## Four rules that shaped the format

  **Templates address `config.*` and `secrets.*`, and those are the only two
  namespaces this tier adds.** The legal leaves under each come from this one
  document's own `config_schema`, so they are handed to
  `ServiceRadar.Notifications.Template.Syntax` as exact `:extra_paths`. A
  non-secret property is addressable as `config.<name>`; a property marked
  `secretRef: true` is addressable ONLY as `secrets.<runtime name>` - the name
  `ServiceRadar.Plugins.SecretRefs.runtime_field_name/1` produces, which is what
  the dispatcher puts in `Transport.Request.secrets`. `config` holds the secret
  *reference*, never the secret, and the two namespaces stay disjoint so a
  document cannot address one and mean the other.

  **A `json` body is a document, not a string.** `body_format: json` requires
  `body` to be a JSON object or array whose leaves are template strings.
  Substituting an alert title into hand-written JSON text is a quoting bug
  waiting for the first message containing a `"`, and
  `ServiceRadar.Notifications.Transports.HTTP` passes the body to `Req`'s `json:`
  option, which would encode a rendered string as a JSON *string literal* rather
  than as the object the author drew. So the string form is refused with a
  message that says which shape to use instead. `form` takes a flat map; `text`
  takes a template string.

  **`success.status` is 2xx only.** The HTTP layer sets `redirect: false`, so a
  3xx is never success, and a document that called a 4xx "success" would record
  deliveries as `:sent` that the destination rejected - the silent failure the
  whole platform exists to prevent. `failure.retryable_status` is correspondingly
  non-2xx. The two sets may not overlap. Anything in neither set is a terminal
  failure, per the spec.

  **The tier declares only what it can honour.** `capabilities` is restricted to
  `#{inspect([:send, :test, :rich_payload])}`; a request-template engine has no
  thread state, no inbound endpoint, and no second request template, so
  `threading`, `inbound_callback`, `attachments`, and `resolve_update` cannot be
  declared here - they are the `:wasm_plugin` tier's business. `routes` is
  restricted to `[:control_plane]` for the same reason: there is no plugin-backed
  edge execution path for a declarative provider, and the spec forbids declaring
  a route that does not exist.

  ## What is rejected, and why it is rejected HERE

  Rejection at authoring time is the point of a validator. An operator writing a
  document sees only what this module tells them, and a notification provider is
  exercised for the first time during an incident.

  | Rejected | Because |
  | --- | --- |
  | Any unknown key, at any level | The format is CLOSED; a typo'd key that is ignored is a setting that silently did nothing |
  | `html`, `raw_html`, `javascript`, `js`, `component`, `component_ref`, `live_view`, `react`, `ui_code` - at ANY depth | A provider describes its UI declaratively via `config_schema` and never ships markup (design D9, matching `Plugins.Manifest`) |
  | `<%`, `%>`, `{%`, `%}`, `\#{` in ANY string | Not only in templates: a code construct anywhere in the document means somebody expected a programming language |
  | A variable path outside the catalog plus this document's `config.*` / `secrets.*` | It renders as an empty string at dispatch, which is a page turning into silence |
  | A filter outside `Template.Syntax.filters/0` | Same |
  | A `config_schema` that fails `Plugins.ConfigSchema` | The channel form is generated from it |
  | A credential-shaped field name without `secretRef: true` | `NotificationChannel.config` is not a sensitive column |
  | A credential-shaped header whose value has no `secrets.*` reference | A literal token in the document lands in the non-sensitive `definition` column |
  | A literal `http://` URL, or one with no scheme | `ServiceRadar.Policies.OutboundURLPolicy` answers `:disallowed_scheme` at dispatch; refusing at save time is the whole point |
  | A method outside `POST`/`PUT`/`PATCH` | The engine issues body-carrying requests only |

  The outbound URL policy still runs on the RESOLVED url at request time - it has
  to, because channel configuration decides the effective host and only the
  engine has it. What is checked here is what can be decided from the document
  alone, and no DNS is performed: this module is pure, so its tests are
  `async: true`.

  ## Supply format

  YAML or JSON, operator's choice. `yaml_elixir` is already a direct dependency
  of `serviceradar_core` (it parses every plugin manifest), so YAML costs no new
  dependency; `Jason` handles the JSON case. `from_string/1` sniffs a leading
  `{` and picks. Input is capped at 64 KiB, and YAML decoding
  runs in a heap-bounded, monitored process that is killed on overrun: a decoder
  can materialise far more than it was given (an anchor-expansion bomb is the
  classic case) and that happens during parsing, before `parse/1` would ever get
  to count nodes.

  **Do not use YAML anchors, aliases, or merge keys.** Measured against
  `yaml_elixir` 2.12.2 / `yamerl` 0.10.0, the behaviour is inconsistent rather
  than uniformly absent, which is worse:

    * an alias to a BLOCK-style collection, or to a scalar, resolves correctly;
    * an alias to a FLOW-style collection (`&h {k: v}`, `&t [a, b]`) collapses to
      the first scalar of the anchored node, so the document decodes to something
      other than what it says;
    * merge keys (`<<:`) are not implemented at all - the key survives literally
      as `"<<1"`, which surfaces as `request.<<1 is not a key of request` plus
      phantom "is required" errors for whatever the merge was meant to supply.

  Since the format is closed, there is also nowhere legal to define a top-level
  anchor in the first place. Write the value out, or supply JSON. The upload UI's
  rendered request preview (task 2.3.1) is what shows an operator that a document
  decoded to something other than what they wrote.

  `parse/1` itself accepts a plain map, which is how the seeded catalog and the
  `jsonb` round-trip arrive. Keys may be atoms or strings and are stringified;
  no atom is ever created from document content.

  ## For the engine and the seeder

  `parse/1` returns a struct that answers every question a request needs without
  re-reading the document:

    * `request.method` / `.url` / `.headers` / `.body_format` / `.body`
    * `classify_status/2` -> `:success | :retryable | :permanent`
    * `retry_after_header` (already downcased for `Transports.HTTP.header/2`)
    * `extract_correlation_id/2`
    * `config_paths/1`, `secret_paths/1`, `templates/1` for previews and forms

  `to_map/1` is the canonical JSON-safe form, and it is what belongs in
  `NotificationProvider.definition`: storing the canonical form rather than the
  bytes an operator uploaded means the stored document is exactly the one that
  was validated, and it makes `SeedFingerprint` comparisons stable across the
  `jsonb` round-trip. `parse(to_map(definition))` returns the same struct.

  Two things this module deliberately does NOT do, because it never sees a
  provider row:

    * It does not check `key` against `NotificationProvider.provider_key`. The
      caller that writes the row owns that equality, and the spec requires it.
    * It does not render. Render with
      `ServiceRadar.Notifications.Renderer.render_string/4`, passing
      `extra_paths: config_paths(definition) ++ secret_paths(definition)` and a
      context carrying `"config"` and `"secrets"`. That is the same restricted
      engine every notification body uses; there is no second one.

  ## Purity

  Pure, apart from the heap guard `from_yaml/1` spawns. No database, no clock, no
  network, no `String.to_atom/1`, no `Code.eval`, no `EEx`.

  See `openspec/changes/add-notification-platform/design.md` (D2, D9, Security)
  and the `notification-providers` spec, "Declarative Provider Request Template
  Document".
  """

  alias ServiceRadar.Notifications.Declarative.Definition.Correlation
  alias ServiceRadar.Notifications.Declarative.Definition.Request
  alias ServiceRadar.Notifications.Template.Syntax
  alias ServiceRadar.Notifications.Transport
  alias ServiceRadar.Plugins.ConfigSchema
  alias ServiceRadar.Plugins.SecretRefs

  @schema_versions [1]

  # Body-carrying methods only. A declarative provider always sends a payload;
  # GET and DELETE would need a document shape that has no body at all.
  @methods %{"POST" => :post, "PUT" => :put, "PATCH" => :patch}
  @body_formats %{"json" => :json, "form" => :form, "text" => :text}
  @correlation_sources %{"body" => :body, "header" => :header}

  # What a request-template engine can actually do. See the moduledoc.
  @capabilities [:send, :test, :rich_payload]
  @routes [:control_plane]

  # Identical to `ServiceRadar.Plugins.Manifest`'s action-descriptor list, and
  # compared case-insensitively rather than exactly, so `RawHtml` is refused too.
  @forbidden_keys ~w(html raw_html javascript js component component_ref live_view react ui_code)

  # Name segments that mean "this field carries a credential". Split on `_` and
  # `-` rather than matched as substrings: `auth_mode` is an ordinary field and a
  # substring match on "auth" would force it into the secret broker.
  @credential_segments ~w(
    token secret password passwd passphrase apikey credential credentials key authorization
  )

  @scalar_types ~w(string integer number boolean)

  # RFC 7230 token. CR and LF outside it is exactly the header-injection case.
  @header_name_regex ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
  @key_regex ~r/\A[a-z][a-z0-9_-]{0,62}\z/
  @icon_regex ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/
  @scheme_regex ~r{\A(?<scheme>[a-zA-Z][a-zA-Z0-9+.\-]*)://}
  @status_range_regex ~r/\A(?<low>\d{3})\s*-\s*(?<high>\d{3})\z/

  @top_level_required ~w(
    schema_version key display_name capabilities payload_formats config_schema request success failure
  )
  @top_level_optional ~w(description icon routes timeout_ms response)

  @request_required ~w(method url body_format body)
  @request_optional ~w(headers)

  @success_required ~w(status)
  @failure_required ~w(retryable_status)
  @failure_optional ~w(retry_after_header)

  @response_optional ~w(external_correlation_id)
  @correlation_required ~w(from)
  @correlation_optional ~w(path header)

  # Bounds. A provider document is a few kilobytes; everything past that is a
  # mistake or an attack, and both want the same answer.
  @max_input_bytes 64 * 1024
  @max_depth 12
  @max_nodes 2_000
  @max_key_bytes 200
  @max_display_name 120
  @max_description 1_000
  @max_url_bytes 4_000
  @max_headers 32
  @max_status_entries 32
  @max_body_keys 200
  @max_correlation_segments 8
  @max_correlation_bytes 512
  @max_timeout_ms 120_000
  @allowed_port 443

  # A YAML anchor bomb expands inside yamerl, so counting nodes afterwards is too
  # late. The decode runs in an unlinked, monitored process with a bounded heap:
  # an overrun kills that process and comes back as a parse error.
  @yaml_heap_words 8_000_000
  @yaml_timeout_ms 5_000

  @type error :: %{path: String.t(), message: String.t()}

  @type status_range :: {100..599, 100..599}

  defmodule Request do
    @moduledoc """
    The single HTTP request a declarative provider issues.

    Every field is already normalised: `method` is an atom from a fixed map,
    header names are downcased to match what `Transports.HTTP` puts on the wire,
    and `body` is the shape `body_format` requires. The engine renders the
    templates and hands the result to `Transports.HTTP.request/4`; it decides
    nothing else.
    """

    @enforce_keys [:method, :url, :body_format, :body]

    defstruct [:method, :url, :body_format, :body, headers: %{}]

    @type method :: :post | :put | :patch
    @type body_format :: :json | :form | :text

    @type t :: %__MODULE__{
            method: method(),
            url: String.t(),
            headers: %{optional(String.t()) => String.t()},
            body_format: body_format(),
            body: map() | list() | String.t()
          }
  end

  defmodule Correlation do
    @moduledoc """
    Where the provider-side handle lives in a successful response.

    `external_correlation_id` is what lets a later inbound interaction resolve
    back to the delivery that produced it (see `Notifications.Transport`), so a
    declarative provider that returns one says where. `from: :body` reads a path
    of literal map keys - not JSONPath, which is an expression language and this
    tier does not have one. `from: :header` names a response header.
    """

    @enforce_keys [:from]

    defstruct [:from, :header, path: []]

    @type t :: %__MODULE__{
            from: :body | :header,
            path: [String.t()],
            header: String.t() | nil
          }
  end

  @enforce_keys [
    :schema_version,
    :key,
    :display_name,
    :capabilities,
    :payload_formats,
    :config_schema,
    :request,
    :success_status,
    :retryable_status
  ]

  defstruct [
    :schema_version,
    :key,
    :display_name,
    :description,
    :icon,
    :capabilities,
    :payload_formats,
    :config_schema,
    :request,
    :success_status,
    :retryable_status,
    :timeout_ms,
    :correlation,
    routes: [:control_plane],
    retry_after_header: "retry-after"
  ]

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          key: String.t(),
          display_name: String.t(),
          description: String.t() | nil,
          icon: String.t() | nil,
          capabilities: [Transport.capability()],
          payload_formats: [Transport.payload_format()],
          routes: [Transport.execution_route()],
          config_schema: map(),
          request: Request.t(),
          success_status: [status_range()],
          retryable_status: [status_range()],
          retry_after_header: String.t(),
          timeout_ms: pos_integer() | nil,
          correlation: Correlation.t() | nil
        }

  # --- published vocabulary -------------------------------------------------

  @doc "Document versions this platform understands. An unknown one is refused."
  @spec supported_schema_versions() :: [pos_integer()]
  def supported_schema_versions, do: @schema_versions

  @doc "The HTTP methods a declarative request may use."
  @spec allowed_methods() :: [String.t()]
  def allowed_methods, do: Map.keys(@methods)

  @doc "The body formats, and therefore the permitted shapes of `request.body`."
  @spec allowed_body_formats() :: [String.t()]
  def allowed_body_formats, do: Map.keys(@body_formats)

  @doc """
  The capabilities this tier may declare.

  Narrower than `ServiceRadar.Notifications.Transport.capabilities/0` on purpose;
  see the moduledoc.
  """
  @spec allowed_capabilities() :: [Transport.capability()]
  def allowed_capabilities, do: @capabilities

  @doc "The execution routes this tier may declare."
  @spec allowed_routes() :: [Transport.execution_route()]
  def allowed_routes, do: @routes

  @doc """
  The nine keys a provider may never use, at any depth.

  Same list as `ServiceRadar.Plugins.Manifest` refuses in an action descriptor.
  """
  @spec forbidden_keys() :: [String.t()]
  def forbidden_keys, do: @forbidden_keys

  # --- entry points ---------------------------------------------------------

  @doc """
  Parses and validates a definition document.

  Accepts a map (atom or string keys) or a YAML/JSON string. Returns
  `{:ok, %Definition{}}`, or `{:error, errors}` with EVERY problem the document
  has - the upload UI lists them all rather than making an operator re-submit to
  discover the next one. Each error names the offending path.
  """
  @spec parse(term()) :: {:ok, t()} | {:error, [error()]}
  def parse(document) when is_binary(document) do
    case from_string(document) do
      {:ok, decoded} -> parse(decoded)
      {:error, errors} -> {:error, errors}
    end
  end

  def parse(document) when is_map(document) and not is_struct(document) do
    document |> stringify() |> do_parse()
  end

  def parse(_document) do
    {:error,
     [
       error(
         "document",
         "a provider definition must be a mapping of keys to values (YAML or JSON)"
       )
     ]}
  end

  @doc """
  `parse/1` reduced to a verdict, for a save-time check that does not need the
  struct.
  """
  @spec validate(term()) :: :ok | {:error, [error()]}
  def validate(document) do
    case parse(document) do
      {:ok, _definition} -> :ok
      {:error, errors} -> {:error, errors}
    end
  end

  @doc """
  Decodes a YAML or JSON document into a map without validating it.

  A leading `{` selects JSON; everything else is YAML. Both refuse a non-mapping
  top level, because a list or a scalar is not a provider.
  """
  @spec from_string(term()) :: {:ok, map()} | {:error, [error()]}
  def from_string(binary) when is_binary(binary) do
    if String.starts_with?(String.trim_leading(binary), "{") do
      from_json(binary)
    else
      from_yaml(binary)
    end
  end

  def from_string(_other) do
    {:error, [error("document", "a provider definition document must be a string")]}
  end

  @doc "Decodes a JSON document into a map without validating it."
  @spec from_json(term()) :: {:ok, map()} | {:error, [error()]}
  def from_json(binary) when is_binary(binary) do
    with :ok <- check_input_size(binary) do
      case Jason.decode(binary) do
        {:ok, %{} = decoded} ->
          {:ok, decoded}

        {:ok, _other} ->
          {:error, [error("document", "the JSON top level must be an object")]}

        {:error, exception} ->
          {:error, [error("document", "invalid JSON: " <> message(exception))]}
      end
    end
  end

  def from_json(_other) do
    {:error, [error("document", "a provider definition document must be a string")]}
  end

  @doc """
  Decodes a YAML document into a map without validating it.

  Runs in a heap-bounded, monitored process; see the moduledoc.
  """
  @spec from_yaml(term()) :: {:ok, map()} | {:error, [error()]}
  def from_yaml(binary) when is_binary(binary) do
    with :ok <- check_input_size(binary) do
      case bounded_yaml(binary) do
        {:ok, %{} = decoded} ->
          {:ok, decoded}

        {:ok, _other} ->
          {:error, [error("document", "the YAML top level must be a mapping")]}

        {:error, :bounded} ->
          {:error,
           [
             error(
               "document",
               "this YAML did not decode within the memory and time bounds; a document with " <>
                 "expanding anchors or aliases is refused"
             )
           ]}

        {:error, reason} ->
          {:error, [error("document", "invalid YAML: " <> message(reason))]}
      end
    end
  end

  def from_yaml(_other) do
    {:error, [error("document", "a provider definition document must be a string")]}
  end

  # --- accessors the engine, the seeder, and the UI use ---------------------

  @doc """
  The canonical JSON-safe document.

  This is what belongs in `NotificationProvider.definition`; see the moduledoc.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = definition) do
    %{
      "schema_version" => definition.schema_version,
      "key" => definition.key,
      "display_name" => definition.display_name,
      "capabilities" => Enum.map(definition.capabilities, &Atom.to_string/1),
      "payload_formats" => Enum.map(definition.payload_formats, &Atom.to_string/1),
      "routes" => Enum.map(definition.routes, &Atom.to_string/1),
      "config_schema" => definition.config_schema,
      "request" => request_to_map(definition.request),
      "success" => %{"status" => Enum.map(definition.success_status, &range_to_entry/1)},
      "failure" => %{
        "retryable_status" => Enum.map(definition.retryable_status, &range_to_entry/1),
        "retry_after_header" => definition.retry_after_header
      }
    }
    |> put_present("description", definition.description)
    |> put_present("icon", definition.icon)
    |> put_present("timeout_ms", definition.timeout_ms)
    |> put_present("response", correlation_to_map(definition.correlation))
  end

  @doc """
  What a response status means to THIS provider.

  `:success` and `:retryable` come from the document's own sets; everything else
  is `:permanent`, per the spec. Note this classifies the STATUS only - the
  delivery state it implies is still `Transport.Result.outcome/2`'s decision, and
  is not re-derived here or anywhere else.
  """
  @spec classify_status(t(), term()) :: :success | :retryable | :permanent
  def classify_status(%__MODULE__{} = definition, status) when is_integer(status) do
    cond do
      in_ranges?(definition.success_status, status) -> :success
      in_ranges?(definition.retryable_status, status) -> :retryable
      true -> :permanent
    end
  end

  def classify_status(%__MODULE__{}, _status), do: :permanent

  @doc """
  The provider-side handle in a successful response, or nil.

  `response` is the `Transports.HTTP` response map (`%{status:, headers:,
  body:}`) or anything with the same two keys. The result is truncated to
  #{@max_correlation_bytes} bytes, because it is persisted on the delivery row
  and a destination does not get to decide how much it writes there.
  """
  @spec extract_correlation_id(t(), term()) :: String.t() | nil
  def extract_correlation_id(%__MODULE__{correlation: nil}, _response), do: nil

  def extract_correlation_id(%__MODULE__{correlation: correlation}, response)
      when is_map(response) do
    correlation
    |> correlation_value(response)
    |> normalize_correlation_id()
  end

  def extract_correlation_id(%__MODULE__{}, _response), do: nil

  @doc """
  The `config.*` paths this document's templates may address, sorted.
  """
  @spec config_paths(t()) :: [String.t()]
  def config_paths(%__MODULE__{config_schema: config_schema}) do
    {config_paths, _secret_paths, _unaddressable} = schema_paths(config_schema)
    config_paths
  end

  @doc """
  The `secrets.*` paths this document's templates may address, sorted.

  Each is the runtime name of a `secretRef: true` property, which is the key the
  dispatcher puts in `Transport.Request.secrets`.
  """
  @spec secret_paths(t()) :: [String.t()]
  def secret_paths(%__MODULE__{config_schema: config_schema}) do
    {_config_paths, secret_paths, _unaddressable} = schema_paths(config_schema)
    secret_paths
  end

  @doc """
  Every template in the document as `{path, template}`, in document order.

  The upload UI renders these to preview the resulting request without issuing
  one.
  """
  @spec templates(t()) :: [{String.t(), String.t()}]
  def templates(%__MODULE__{request: request}) do
    header_entries =
      request.headers
      |> Enum.sort_by(fn {name, _value} -> name end)
      |> Enum.map(fn {name, value} -> {"request.headers." <> name, value} end)

    {body_entries, _errors} = scan_body(request.body_format, request.body, "request.body")

    [{"request.url", request.url}] ++ header_entries ++ body_entries
  end

  @doc "One operator-readable sentence for a list of errors."
  @spec describe_errors([error()]) :: String.t()
  def describe_errors(errors) when is_list(errors) do
    Enum.map_join(errors, "; ", fn %{path: path, message: message} -> "#{path} #{message}" end)
  end

  # --- validation -----------------------------------------------------------

  defp do_parse(document) do
    case guard_document(document) do
      [] -> build(document)
      errors -> {:error, sort_errors(errors)}
    end
  end

  # Whole-document guards run first and alone. A document carrying a `javascript`
  # key or an EEx tag is refused as a document; listing its other spelling
  # mistakes underneath that would bury the finding that matters.
  defp guard_document(document) do
    document
    |> walk("", 0, %{errors: [], nodes: 0})
    |> then(fn acc ->
      if acc.nodes > @max_nodes do
        [
          error("document", "has more than #{@max_nodes} values; a provider document is small")
          | acc.errors
        ]
      else
        acc.errors
      end
    end)
  end

  defp walk(_value, path, depth, acc) when depth > @max_depth do
    %{acc | errors: [error(path, "is nested deeper than #{@max_depth} levels") | acc.errors]}
  end

  defp walk(%{} = value, path, depth, acc) when not is_struct(value) do
    acc = %{acc | nodes: acc.nodes + 1}

    Enum.reduce(value, acc, fn {key, child}, acc ->
      key_string = stringify_key(key)
      child_path = join(path, key_string)

      acc
      |> check_key(key_string, child_path)
      |> then(&walk(child, child_path, depth + 1, &1))
    end)
  end

  defp walk(value, path, depth, acc) when is_list(value) do
    acc = %{acc | nodes: acc.nodes + 1}

    value
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {child, index}, acc ->
      walk(child, path <> "[#{index}]", depth + 1, acc)
    end)
  end

  defp walk(value, path, _depth, acc) when is_binary(value) do
    acc = %{acc | nodes: acc.nodes + 1}

    case Enum.find(Syntax.code_markers(), &String.contains?(value, &1)) do
      nil ->
        acc

      marker ->
        %{
          acc
          | errors: [
              error(
                path,
                "contains the code construct \"#{marker}\"; a provider definition is data, " <>
                  "never code - expressive logic requires a wasm_plugin provider"
              )
              | acc.errors
            ]
        }
    end
  end

  defp walk(value, _path, _depth, acc) when is_number(value) do
    %{acc | nodes: acc.nodes + 1}
  end

  # A seeded catalog entry is written in Elixir and says `capabilities:
  # [:send, :test]`; the same document read back from `jsonb` says
  # `["send", "test"]`. Both are the document, so an atom is a value here - and
  # it is scanned as its own name, because `:"<%= x %>"` is still a code
  # construct. `nil`, `true`, and `false` arrive through this clause too.
  defp walk(value, path, depth, acc) when is_atom(value) do
    walk(Atom.to_string(value), path, depth, acc)
  end

  defp walk(_value, path, _depth, acc) do
    %{
      acc
      | nodes: acc.nodes + 1,
        errors: [error(path, "is not a value a JSON or YAML document can carry") | acc.errors]
    }
  end

  # `request.body` is the DESTINATION's payload, so its keys belong to the
  # destination's API vocabulary and not to ServiceRadar's document structure.
  # `component` is a real PagerDuty Events API v2 field; `html` is a real field
  # in more than one chat API. Refusing those key NAMES there does not protect
  # anything - ServiceRadar never interprets a request body as UI - and it makes
  # the tier unable to express destinations it is supposed to cover.
  #
  # The security control that matters is unchanged and still applies everywhere,
  # including inside the body: every VALUE is scanned for code constructs, and
  # every template is validated against the published variable catalog and
  # filter set. A body key cannot smuggle markup, because a body value cannot.
  defp body_scoped?(path) do
    path == "request.body" or String.starts_with?(path, "request.body.") or
      String.starts_with?(path, "request.body[")
  end

  defp check_key(acc, key, path) do
    cond do
      String.downcase(key) in @forbidden_keys and body_scoped?(path) ->
        acc

      String.downcase(key) in @forbidden_keys ->
        %{
          acc
          | errors: [
              error(
                path,
                "is not allowed anywhere in a provider definition; a provider describes its " <>
                  "UI declaratively through config_schema and never ships markup or code"
              )
              | acc.errors
            ]
        }

      byte_size(key) > @max_key_bytes ->
        %{acc | errors: [error(path, "is longer than #{@max_key_bytes} bytes") | acc.errors]}

      true ->
        acc
    end
  end

  defp build(document) do
    errors = closed_keys(document, "", @top_level_required, @top_level_optional)

    {schema_version, errors} = take_schema_version(document, errors)
    {key, errors} = take_key(document, errors)
    {display_name, errors} = take_display_name(document, errors)
    {description, errors} = take_description(document, errors)
    {icon, errors} = take_icon(document, errors)
    {capabilities, errors} = take_capabilities(document, errors)
    {payload_formats, errors} = take_payload_formats(document, errors)
    {routes, errors} = take_routes(document, errors)
    {timeout_ms, errors} = take_timeout(document, errors)
    {config_schema, errors} = take_config_schema(document, errors)
    {allowed_paths, hint} = template_context(config_schema)
    {request, errors} = take_request(document, allowed_paths, hint, errors)
    {success, errors} = take_success(document, errors)
    {retryable, retry_after_header, errors} = take_failure(document, errors)
    errors = check_status_overlap(success, retryable, errors)
    {correlation, errors} = take_response(document, errors)

    case sort_errors(errors) do
      [] ->
        {:ok,
         %__MODULE__{
           schema_version: schema_version,
           key: key,
           display_name: display_name,
           description: description,
           icon: icon,
           capabilities: capabilities,
           payload_formats: payload_formats,
           routes: routes,
           config_schema: config_schema,
           request: request,
           success_status: success,
           retryable_status: retryable,
           retry_after_header: retry_after_header,
           timeout_ms: timeout_ms,
           correlation: correlation
         }}

      errors ->
        {:error, errors}
    end
  end

  # --- top-level fields -----------------------------------------------------

  defp take_schema_version(document, errors) do
    case Map.fetch(document, "schema_version") do
      {:ok, version} when version in @schema_versions ->
        {version, errors}

      {:ok, version} when is_integer(version) ->
        {nil,
         [
           error(
             "schema_version",
             "#{version} is not a supported document version; this platform reads " <>
               "#{inspect(@schema_versions)}"
           )
           | errors
         ]}

      {:ok, _version} ->
        {nil,
         [
           error("schema_version", "must be an integer, one of #{inspect(@schema_versions)}")
           | errors
         ]}

      :error ->
        {nil, errors}
    end
  end

  defp take_key(document, errors) do
    case Map.fetch(document, "key") do
      {:ok, key} when is_binary(key) ->
        if Regex.match?(@key_regex, key) do
          {key, errors}
        else
          {nil,
           [
             error(
               "key",
               "must be a lower-case provider key: a letter followed by letters, digits, " <>
                 "underscores, or hyphens (up to 63 characters). It becomes the provider_key."
             )
             | errors
           ]}
        end

      {:ok, _key} ->
        {nil, [error("key", "must be a string") | errors]}

      :error ->
        {nil, errors}
    end
  end

  defp take_display_name(document, errors) do
    case Map.fetch(document, "display_name") do
      {:ok, name} when is_binary(name) ->
        trimmed = String.trim(name)

        cond do
          trimmed == "" ->
            {nil, [error("display_name", "must not be blank") | errors]}

          String.length(trimmed) > @max_display_name ->
            {nil,
             [
               error("display_name", "must be #{@max_display_name} characters or fewer") | errors
             ]}

          String.contains?(trimmed, ["\r", "\n"]) ->
            {nil, [error("display_name", "must be a single line") | errors]}

          true ->
            {trimmed, errors}
        end

      {:ok, _name} ->
        {nil, [error("display_name", "must be a string") | errors]}

      :error ->
        {nil, errors}
    end
  end

  defp take_description(document, errors) do
    case Map.fetch(document, "description") do
      {:ok, nil} ->
        {nil, errors}

      {:ok, description} when is_binary(description) ->
        if String.length(description) > @max_description do
          {nil,
           [error("description", "must be #{@max_description} characters or fewer") | errors]}
        else
          {presence(description), errors}
        end

      {:ok, _description} ->
        {nil, [error("description", "must be a string") | errors]}

      :error ->
        {nil, errors}
    end
  end

  defp take_icon(document, errors) do
    case Map.fetch(document, "icon") do
      {:ok, nil} ->
        {nil, errors}

      {:ok, icon} when is_binary(icon) ->
        if Regex.match?(@icon_regex, icon) do
          {icon, errors}
        else
          {nil,
           [
             error(
               "icon",
               "must be an icon name: lower-case letters, digits, underscores, or hyphens. " <>
                 "It is a name the UI looks up, never markup."
             )
             | errors
           ]}
        end

      {:ok, _icon} ->
        {nil, [error("icon", "must be a string") | errors]}

      :error ->
        {nil, errors}
    end
  end

  defp take_capabilities(document, errors) do
    case take_atom_list(document, "capabilities", @capabilities) do
      {:ok, []} ->
        {nil, [error("capabilities", "must declare at least send and test") | errors]}

      {:ok, capabilities} ->
        missing = Enum.reject(Transport.required_capabilities(), &(&1 in capabilities))

        if missing == [] do
          {capabilities, errors}
        else
          {nil,
           [
             error(
               "capabilities",
               "must declare #{inspect(missing)}; every provider in every tier implements " <>
                 "send and test so that test-send before saving works uniformly (design D2)"
             )
             | errors
           ]}
        end

      {:error, messages} ->
        {nil, capability_errors(messages) ++ errors}

      :missing ->
        {nil, errors}
    end
  end

  defp capability_errors(messages) do
    hint =
      "; a request-template provider may declare " <>
        inspect(@capabilities) <>
        ". Threading, inbound callbacks, attachments, and resolve updates need a " <>
        "wasm_plugin provider."

    list_errors(messages, "capabilities", hint)
  end

  defp take_payload_formats(document, errors) do
    case take_atom_list(document, "payload_formats", Transport.payload_formats()) do
      {:ok, []} ->
        {nil,
         [
           error(
             "payload_formats",
             "must declare at least one payload format; the renderer negotiates against this list"
           )
           | errors
         ]}

      {:ok, formats} ->
        {formats, errors}

      {:error, messages} ->
        {nil, list_errors(messages, "payload_formats", "") ++ errors}

      :missing ->
        {nil, errors}
    end
  end

  defp take_routes(document, errors) do
    case take_atom_list(document, "routes", @routes) do
      {:ok, []} ->
        {nil, [error("routes", "must declare at least one execution route") | errors]}

      {:ok, routes} ->
        {routes, errors}

      {:error, messages} ->
        {nil, list_errors(messages, "routes", route_hint()) ++ errors}

      :missing ->
        {@routes, errors}
    end
  end

  defp route_hint do
    "; a declarative provider runs on the control plane. There is no plugin-backed " <>
      "edge execution path for an uploaded document, and a route that does not exist " <>
      "may not be declared."
  end

  # The hint explains what the closed vocabulary is, so it belongs on a value
  # that is not in it - and only there. Appending it to "listed twice" would
  # answer a question the author did not ask.
  defp list_errors(messages, path, hint) do
    Enum.map(messages, fn
      {:unknown, message} -> error(path, message <> hint)
      {:duplicate, message} -> error(path, message)
      message -> error(path, message)
    end)
  end

  defp take_timeout(document, errors) do
    case Map.fetch(document, "timeout_ms") do
      {:ok, nil} ->
        {nil, errors}

      {:ok, timeout} when is_integer(timeout) and timeout > 0 and timeout <= @max_timeout_ms ->
        {timeout, errors}

      {:ok, _timeout} ->
        {nil,
         [
           error(
             "timeout_ms",
             "must be a positive integer number of milliseconds, at most #{@max_timeout_ms}"
           )
           | errors
         ]}

      :error ->
        {nil, errors}
    end
  end

  # --- config_schema --------------------------------------------------------

  defp take_config_schema(document, errors) do
    case Map.fetch(document, "config_schema") do
      {:ok, schema} when is_map(schema) and not is_struct(schema) ->
        schema_errors =
          case ConfigSchema.validate_schema(schema) do
            :ok -> []
            {:error, messages} -> Enum.map(messages, &error("config_schema", &1))
          end

        {schema, credential_errors(schema) ++ schema_errors ++ errors}

      {:ok, _schema} ->
        {%{},
         [
           error("config_schema", "must be a JSON Schema object describing the channel fields")
           | errors
         ]}

      :error ->
        {%{}, errors}
    end
  end

  # `NotificationChannel.config` is not a sensitive column. A field whose NAME
  # says credential and which is not routed through the secret broker is a token
  # in plaintext storage, and the operator who wrote the document would have no
  # reason to suspect it.
  defp credential_errors(schema) do
    secret_fields = SecretRefs.secret_ref_fields(schema)

    schema
    |> properties()
    |> Enum.reject(fn {name, _property} -> name in secret_fields end)
    |> Enum.filter(fn {name, _property} -> credential_name?(name) end)
    |> Enum.map(fn {name, _property} ->
      error(
        "config_schema.properties.#{name}",
        "names a credential but is not marked \"secretRef: true\", so its value would be " <>
          "stored in the channel's non-sensitive config column. Mark it secretRef (and " <>
          "optionally credentialKind) and address it in templates as " <>
          "secrets.#{SecretRefs.runtime_field_name(name)}."
      )
    end)
  end

  defp credential_name?(name) do
    name
    |> String.downcase()
    |> String.split(["_", "-"], trim: true)
    |> Enum.any?(&(&1 in @credential_segments))
  end

  # The two namespaces a declarative template adds, as exact paths.
  defp template_context(config_schema) do
    {config_paths, secret_paths, unaddressable} = schema_paths(config_schema)
    {config_paths ++ secret_paths, hint(config_paths, secret_paths, unaddressable)}
  end

  defp schema_paths(config_schema) do
    secret_fields = SecretRefs.secret_ref_fields(config_schema)
    properties = properties(config_schema)

    secret_paths =
      secret_fields
      |> Enum.map(&("secrets." <> SecretRefs.runtime_field_name(&1)))
      |> Enum.sort()

    {addressable, unaddressable} =
      properties
      |> Enum.reject(fn {name, _property} -> name in secret_fields end)
      |> Enum.split_with(fn {_name, property} -> scalar_property?(property) end)

    config_paths =
      addressable |> Enum.map(fn {name, _property} -> "config." <> name end) |> Enum.sort()

    unaddressable =
      unaddressable |> Enum.map(fn {name, _property} -> "config." <> name end) |> Enum.sort()

    {config_paths, secret_paths, unaddressable}
  end

  # An object or an array cannot be substituted into a string, so it is not
  # addressable. A property with no declared type is addressed permissively: the
  # renderer stringifies whatever it resolves.
  defp scalar_property?(property) when is_map(property) do
    case Map.get(property, "type") do
      nil -> true
      type when is_binary(type) -> type in @scalar_types
      _other -> false
    end
  end

  defp scalar_property?(_property), do: false

  defp properties(schema) when is_map(schema) do
    case Map.get(schema, "properties") do
      properties when is_map(properties) and not is_struct(properties) -> properties
      _other -> %{}
    end
  end

  defp properties(_schema), do: %{}

  defp hint(config_paths, secret_paths, unaddressable) do
    available =
      case config_paths ++ secret_paths do
        [] -> "This document's config_schema declares no substitutable field"
        paths -> "This document declares " <> Enum.join(paths, ", ")
      end

    case unaddressable do
      [] ->
        available <> "."

      paths ->
        available <>
          ". Fields declared as an object or an array cannot be substituted into a " <>
          "template: " <> Enum.join(paths, ", ") <> "."
    end
  end

  # --- request --------------------------------------------------------------

  defp take_request(document, allowed_paths, hint, errors) do
    case Map.fetch(document, "request") do
      {:ok, request} when is_map(request) and not is_struct(request) ->
        errors = closed_keys(request, "request", @request_required, @request_optional) ++ errors

        {method, errors} = take_method(request, errors)
        {url, errors} = take_url(request, allowed_paths, hint, errors)
        {body_format, errors} = take_body_format(request, errors)
        {headers, errors} = take_headers(request, body_format, allowed_paths, hint, errors)
        {body, errors} = take_body(request, body_format, allowed_paths, hint, errors)

        if is_nil(method) or is_nil(url) or is_nil(body_format) do
          {nil, errors}
        else
          {%Request{
             method: method,
             url: url,
             headers: headers || %{},
             body_format: body_format,
             body: body
           }, errors}
        end

      {:ok, _request} ->
        {nil, [error("request", "must be a mapping describing the HTTP request") | errors]}

      :error ->
        {nil, errors}
    end
  end

  defp take_method(request, errors) do
    case Map.fetch(request, "method") do
      {:ok, method} when is_binary(method) ->
        case Map.fetch(@methods, String.upcase(method)) do
          {:ok, atom} ->
            {atom, errors}

          :error ->
            {nil,
             [
               error(
                 "request.method",
                 "must be one of #{Enum.join(Enum.sort(Map.keys(@methods)), ", ")}; a " <>
                   "declarative provider always sends a body"
               )
               | errors
             ]}
        end

      {:ok, _method} ->
        {nil, [error("request.method", "must be a string") | errors]}

      :error ->
        {nil, errors}
    end
  end

  defp take_url(request, allowed_paths, hint, errors) do
    case Map.fetch(request, "url") do
      {:ok, url} when is_binary(url) ->
        case url_errors(url, allowed_paths, hint) do
          [] -> {url, errors}
          url_errors -> {nil, url_errors ++ errors}
        end

      {:ok, _url} ->
        {nil, [error("request.url", "must be a template string") | errors]}

      :error ->
        {nil, errors}
    end
  end

  # No DNS here: the effective host is decided by channel configuration and only
  # the engine has it, so the full policy runs at request time on the rendered
  # URL. What the document alone decides is decided now, because a URL that could
  # never pass should not survive a save.
  defp url_errors(url, allowed_paths, hint) do
    trimmed = String.trim(url)

    template_errors =
      case Syntax.validate_template(trimmed, extra_paths: allowed_paths) do
        :ok -> []
        {:error, message} -> [error("request.url", template_message(message, hint))]
      end

    template_errors ++ url_shape_errors(trimmed)
  end

  defp url_shape_errors(url) do
    cond do
      url == "" ->
        [error("request.url", "must not be blank")]

      byte_size(url) > @max_url_bytes ->
        [error("request.url", "must be #{@max_url_bytes} bytes or fewer")]

      # Only the literal parts: `{{ config.host }}` is whitespace *inside* an
      # expression, and the renderer removes it before a socket is opened.
      String.contains?(literal_parts(url), [" ", "\t", "\r", "\n"]) ->
        [error("request.url", "must not contain whitespace; percent-encode it instead")]

      String.starts_with?(url, "{{") ->
        # The scheme itself is substituted. The outbound policy is the only
        # thing that can judge it, and it does, at request time.
        []

      true ->
        scheme_errors(url) ++ literal_url_errors(url)
    end
  end

  defp literal_parts(url), do: Regex.replace(~r/\{\{.*?\}\}/s, url, "")

  defp scheme_errors(url) do
    case Regex.named_captures(@scheme_regex, url) do
      %{"scheme" => scheme} ->
        if String.downcase(scheme) == "https" do
          []
        else
          [
            error(
              "request.url",
              "uses the #{String.downcase(scheme)}:// scheme. The outbound URL policy " <>
                "accepts https only and would answer :disallowed_scheme on every attempt, " <>
                "so this provider could never deliver."
            )
          ]
        end

      nil ->
        [
          error(
            "request.url",
            "must begin with https:// or with a substitution that supplies the scheme, " <>
              "for example {{ config.base_url }}/hooks"
          )
        ]
    end
  end

  # Only when the URL carries no substitution at all is the whole thing knowable
  # from the document.
  defp literal_url_errors(url) do
    if String.contains?(url, "{{") do
      []
    else
      uri = URI.parse(url)

      cond do
        is_nil(uri.host) or uri.host == "" ->
          [error("request.url", "names no host")]

        (uri.port || @allowed_port) != @allowed_port ->
          [
            error(
              "request.url",
              "uses port #{uri.port}. The outbound URL policy allows port " <>
                "#{@allowed_port} only and would answer :disallowed_port."
            )
          ]

        true ->
          []
      end
    end
  end

  defp take_body_format(request, errors) do
    case Map.fetch(request, "body_format") do
      {:ok, format} when is_binary(format) ->
        case Map.fetch(@body_formats, String.downcase(format)) do
          {:ok, atom} ->
            {atom, errors}

          :error ->
            {nil,
             [
               error(
                 "request.body_format",
                 "must be one of #{Enum.join(Enum.sort(Map.keys(@body_formats)), ", ")}"
               )
               | errors
             ]}
        end

      {:ok, _format} ->
        {nil, [error("request.body_format", "must be a string") | errors]}

      :error ->
        {nil, errors}
    end
  end

  defp take_headers(request, body_format, allowed_paths, hint, errors) do
    case Map.fetch(request, "headers") do
      {:ok, headers} when is_map(headers) and not is_struct(headers) ->
        header_errors = header_count_errors(headers) ++ duplicate_header_errors(headers)

        {pairs, pair_errors} =
          Enum.reduce(headers, {%{}, []}, fn {name, value}, {acc, acc_errors} ->
            case header_pair(name, value, body_format, allowed_paths, hint) do
              {:ok, {key, rendered}} -> {Map.put(acc, key, rendered), acc_errors}
              {:error, pair_errors} -> {acc, pair_errors ++ acc_errors}
            end
          end)

        {pairs, header_errors ++ pair_errors ++ errors}

      {:ok, _headers} ->
        {%{},
         [
           error("request.headers", "must be a mapping of header name to template string")
           | errors
         ]}

      :error ->
        {%{}, errors}
    end
  end

  defp header_count_errors(headers) do
    if map_size(headers) > @max_headers do
      [error("request.headers", "declares more than #{@max_headers} headers")]
    else
      []
    end
  end

  # Header names are case-insensitive on the wire, so two spellings of one name
  # are a document that means two different things depending on map ordering.
  defp duplicate_header_errors(headers) do
    headers
    |> Map.keys()
    |> Enum.map(&(&1 |> stringify_key() |> String.downcase()))
    |> Enum.frequencies()
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> Enum.map(fn {name, _count} ->
      error(
        "request.headers." <> name,
        "is declared more than once; header names are case-insensitive"
      )
    end)
  end

  defp header_pair(name, value, body_format, allowed_paths, hint) do
    key = name |> stringify_key() |> String.downcase()
    path = "request.headers." <> key

    cond do
      not Regex.match?(@header_name_regex, key) ->
        {:error, [error(path, "is not a valid HTTP header name")]}

      not is_binary(value) ->
        {:error, [error(path, "must be a template string")]}

      String.contains?(value, ["\r", "\n"]) ->
        {:error, [error(path, "must be a single line; a newline in a header value is injection")]}

      true ->
        case header_value_errors(key, value, path, body_format, allowed_paths, hint) do
          [] -> {:ok, {key, value}}
          errors -> {:error, errors}
        end
    end
  end

  defp header_value_errors(key, value, path, body_format, allowed_paths, hint) do
    template_errors =
      case Syntax.validate_template(value, extra_paths: allowed_paths) do
        :ok -> []
        {:error, message} -> [error(path, template_message(message, hint))]
      end

    template_errors ++
      credential_header_errors(key, value, path) ++
      content_type_errors(key, value, path, body_format)
  end

  # `definition` is not a sensitive column either. A credential-shaped header
  # whose value is a literal - or which reads from `config` - puts the token in
  # plaintext storage; it has to come from the broker.
  defp credential_header_errors(key, value, path) do
    if credential_name?(key) and not String.contains?(value, "secrets.") do
      [
        error(
          path,
          "carries a credential, so its value must come from a secrets.* reference such as " <>
            "\"Bearer {{ secrets.token }}\". A literal credential would be stored in the " <>
            "provider definition, which is not a sensitive column."
        )
      ]
    else
      []
    end
  end

  defp content_type_errors("content-type", value, path, body_format) do
    expected = content_type_prefix(body_format)

    cond do
      is_nil(expected) ->
        []

      String.contains?(value, "{{") ->
        [error(path, "must be a literal media type, not a template")]

      String.starts_with?(String.downcase(String.trim(value)), expected) ->
        []

      true ->
        [
          error(
            path,
            "is \"#{value}\" but request.body_format is #{body_format}, which sends " <>
              "#{expected}. Make the two agree, or change body_format."
          )
        ]
    end
  end

  defp content_type_errors(_key, _value, _path, _body_format), do: []

  defp content_type_prefix(:json), do: "application/json"
  defp content_type_prefix(:form), do: "application/x-www-form-urlencoded"
  defp content_type_prefix(_body_format), do: nil

  defp take_body(request, body_format, allowed_paths, hint, errors) do
    case Map.fetch(request, "body") do
      {:ok, body} ->
        case body_shape_errors(body_format, body) do
          [] ->
            {entries, scan_errors} = scan_body(body_format, body, "request.body")
            {body, template_errors(entries, allowed_paths, hint) ++ scan_errors ++ errors}

          shape_errors ->
            {nil, shape_errors ++ errors}
        end

      :error ->
        {nil, errors}
    end
  end

  defp body_shape_errors(:json, body) when is_map(body) and not is_struct(body), do: []
  defp body_shape_errors(:json, body) when is_list(body), do: []

  defp body_shape_errors(:json, _body) do
    [
      error(
        "request.body",
        "must be a JSON object or array whose leaves are template strings when " <>
          "body_format is json. A hand-written JSON string is refused: substituting a " <>
          "value containing a quote would break it, and the HTTP layer encodes the body " <>
          "as a term, so a string would go out as a JSON string literal."
      )
    ]
  end

  defp body_shape_errors(:form, body) when is_map(body) and not is_struct(body), do: []

  defp body_shape_errors(:form, _body) do
    [
      error(
        "request.body",
        "must be a flat mapping of field name to template string when body_format is form"
      )
    ]
  end

  defp body_shape_errors(:text, body) when is_binary(body), do: []

  defp body_shape_errors(:text, _body) do
    [error("request.body", "must be a template string when body_format is text")]
  end

  defp body_shape_errors(nil, _body), do: []

  # Collects every template in the body with its path, and reports the shape
  # problems only a walk can see. Used by `templates/1` too, so the preview and
  # the validator cannot disagree about where the templates are.
  defp scan_body(:text, body, path) when is_binary(body), do: {[{path, body}], []}

  defp scan_body(:form, body, path) when is_map(body) and not is_struct(body) do
    Enum.reduce(body, {[], []}, fn {name, value}, {entries, errors} ->
      key = stringify_key(name)
      field_path = join(path, key)

      cond do
        String.contains?(key, "{{") ->
          {entries,
           [error(field_path, "form field names must be literal, not templates") | errors]}

        is_binary(value) ->
          {entries ++ [{field_path, value}], errors}

        is_number(value) or is_boolean(value) ->
          {entries, errors}

        true ->
          {entries,
           [
             error(
               field_path,
               "must be a template string, a number, or a boolean; a form body is flat"
             )
             | errors
           ]}
      end
    end)
  end

  defp scan_body(:json, body, path), do: scan_json(body, path, {[], []})

  defp scan_body(_body_format, _body, _path), do: {[], []}

  defp scan_json(value, path, {entries, errors}) when is_map(value) and not is_struct(value) do
    errors =
      if map_size(value) > @max_body_keys do
        [error(path, "has more than #{@max_body_keys} keys") | errors]
      else
        errors
      end

    Enum.reduce(value, {entries, errors}, fn {key, child}, acc ->
      key_string = stringify_key(key)
      child_path = join(path, key_string)

      if String.contains?(key_string, "{{") do
        {acc_entries, acc_errors} = acc

        {acc_entries,
         [
           error(
             child_path,
             "JSON body keys must be literal; only values may be templates"
           )
           | acc_errors
         ]}
      else
        scan_json(child, child_path, acc)
      end
    end)
  end

  defp scan_json(value, path, {entries, errors}) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce({entries, errors}, fn {child, index}, acc ->
      scan_json(child, path <> "[#{index}]", acc)
    end)
  end

  defp scan_json(value, path, {entries, errors}) when is_binary(value) do
    {entries ++ [{path, value}], errors}
  end

  defp scan_json(value, _path, acc) when is_nil(value) or is_boolean(value) or is_number(value) do
    acc
  end

  defp scan_json(_value, path, {entries, errors}) do
    {entries, [error(path, "must be a JSON value") | errors]}
  end

  defp template_errors(entries, allowed_paths, hint) do
    Enum.flat_map(entries, fn {path, template} ->
      case Syntax.validate_template(template, extra_paths: allowed_paths) do
        :ok -> []
        {:error, message} -> [error(path, template_message(message, hint))]
      end
    end)
  end

  defp template_message(message, hint), do: "is not a valid template: " <> message <> ". " <> hint

  # --- success / failure ----------------------------------------------------

  defp take_success(document, errors) do
    case Map.fetch(document, "success") do
      {:ok, success} when is_map(success) and not is_struct(success) ->
        errors = closed_keys(success, "success", @success_required, []) ++ errors

        case Map.fetch(success, "status") do
          {:ok, status} ->
            case status_ranges(status, "success.status", 200..299) do
              {:ok, []} ->
                {[], [error("success.status", "must list at least one status code") | errors]}

              {:ok, ranges} ->
                {ranges, errors}

              {:error, status_errors} ->
                {[], status_errors ++ errors}
            end

          :error ->
            {[], errors}
        end

      {:ok, _success} ->
        {[],
         [
           error("success", "must be a mapping with a status list, for example [200, 204]")
           | errors
         ]}

      :error ->
        {[], errors}
    end
  end

  defp take_failure(document, errors) do
    case Map.fetch(document, "failure") do
      {:ok, failure} when is_map(failure) and not is_struct(failure) ->
        errors = closed_keys(failure, "failure", @failure_required, @failure_optional) ++ errors
        {retryable, errors} = take_retryable(failure, errors)
        {header, errors} = take_retry_after_header(failure, errors)
        {retryable, header, errors}

      {:ok, _failure} ->
        {[], "retry-after",
         [
           error(
             "failure",
             "must be a mapping with retryable_status and optionally retry_after_header"
           )
           | errors
         ]}

      :error ->
        {[], "retry-after", errors}
    end
  end

  defp take_retryable(failure, errors) do
    case Map.fetch(failure, "retryable_status") do
      {:ok, status} ->
        case status_ranges(status, "failure.retryable_status", 100..599) do
          {:ok, ranges} ->
            {ranges, success_range_errors(ranges) ++ errors}

          {:error, status_errors} ->
            {[], status_errors ++ errors}
        end

      :error ->
        {[], errors}
    end
  end

  # A 2xx is what "the destination accepted the payload" means. Calling one
  # retryable would re-send a notification the destination already delivered.
  defp success_range_errors(ranges) do
    ranges
    |> Enum.filter(fn {low, high} -> low <= 299 and high >= 200 end)
    |> Enum.map(fn range ->
      error(
        "failure.retryable_status",
        "lists #{range_to_string(range)}, which covers a 2xx. A 2xx means the destination " <>
          "accepted the payload; retrying it would send the notification twice."
      )
    end)
  end

  defp take_retry_after_header(failure, errors) do
    case Map.fetch(failure, "retry_after_header") do
      {:ok, nil} ->
        {"retry-after", errors}

      {:ok, header} when is_binary(header) ->
        downcased = header |> String.trim() |> String.downcase()

        if Regex.match?(@header_name_regex, downcased) do
          {downcased, errors}
        else
          {"retry-after",
           [error("failure.retry_after_header", "is not a valid HTTP header name") | errors]}
        end

      {:ok, _header} ->
        {"retry-after", [error("failure.retry_after_header", "must be a string") | errors]}

      :error ->
        {"retry-after", errors}
    end
  end

  defp check_status_overlap(success, retryable, errors) do
    overlap =
      success
      |> expand()
      |> MapSet.intersection(expand(retryable))
      |> Enum.sort()

    case overlap do
      [] ->
        errors

      codes ->
        [
          error(
            "failure.retryable_status",
            "overlaps success.status on #{Enum.map_join(codes, ", ", &to_string/1)}; a " <>
              "status cannot be both a success and worth retrying"
          )
          | errors
        ]
    end
  end

  defp status_ranges(entries, path, allowed) when is_list(entries) do
    if length(entries) > @max_status_entries do
      {:error, [error(path, "lists more than #{@max_status_entries} entries")]}
    else
      {ranges, errors} =
        entries
        |> Enum.with_index()
        |> Enum.reduce({[], []}, fn {entry, index}, {ranges, errors} ->
          case status_range(entry, "#{path}[#{index}]", allowed) do
            {:ok, range} -> {ranges ++ [range], errors}
            {:error, message} -> {ranges, errors ++ [message]}
          end
        end)

      case errors ++ duplicate_status_errors(ranges, path) do
        [] -> {:ok, Enum.sort(ranges)}
        errors -> {:error, errors}
      end
    end
  end

  defp status_ranges(_entries, path, _allowed) do
    {:error,
     [
       error(
         path,
         "must be a list of status codes or inclusive ranges, for example [429, \"500-599\"]"
       )
     ]}
  end

  defp status_range(entry, path, allowed) when is_integer(entry) do
    if entry in allowed do
      {:ok, {entry, entry}}
    else
      {:error, error(path, status_message(entry, allowed))}
    end
  end

  defp status_range(entry, path, allowed) when is_binary(entry) do
    case Regex.named_captures(@status_range_regex, String.trim(entry)) do
      %{"low" => low, "high" => high} ->
        low = String.to_integer(low)
        high = String.to_integer(high)

        cond do
          low > high ->
            {:error, error(path, "\"#{entry}\" runs backwards; write the low code first")}

          low not in allowed or high not in allowed ->
            {:error, error(path, status_message(entry, allowed))}

          true ->
            {:ok, {low, high}}
        end

      nil ->
        {:error,
         error(
           path,
           "\"#{entry}\" is not a status code or a range; write 429 or \"500-599\""
         )}
    end
  end

  defp status_range(entry, path, _allowed) do
    {:error, error(path, "#{inspect(entry)} is not a status code or a range")}
  end

  defp status_message(entry, allowed) do
    low = Enum.min(allowed)
    high = Enum.max(allowed)

    "#{inspect(entry)} is outside #{low}-#{high}, the codes this list may contain"
  end

  defp duplicate_status_errors(ranges, path) do
    codes = Enum.flat_map(ranges, fn {low, high} -> Enum.to_list(low..high) end)

    codes
    |> Enum.frequencies()
    |> Enum.filter(fn {_code, count} -> count > 1 end)
    |> Enum.sort()
    |> Enum.map(fn {code, _count} -> error(path, "covers #{code} more than once") end)
  end

  # --- response -------------------------------------------------------------

  defp take_response(document, errors) do
    case Map.fetch(document, "response") do
      {:ok, response} when is_map(response) and not is_struct(response) ->
        errors = closed_keys(response, "response", [], @response_optional) ++ errors

        if map_size(response) == 0 do
          {nil,
           [
             error("response", "must declare external_correlation_id, or be omitted entirely")
             | errors
           ]}
        else
          take_correlation(response, errors)
        end

      {:ok, _response} ->
        {nil, [error("response", "must be a mapping") | errors]}

      :error ->
        {nil, errors}
    end
  end

  defp take_correlation(response, errors) do
    case Map.fetch(response, "external_correlation_id") do
      {:ok, correlation} when is_map(correlation) and not is_struct(correlation) ->
        path = "response.external_correlation_id"

        errors =
          closed_keys(correlation, path, @correlation_required, @correlation_optional) ++ errors

        case Map.get(correlation, "from") do
          "body" -> correlation_from_body(correlation, path, errors)
          "header" -> correlation_from_header(correlation, path, errors)
          nil -> {nil, errors}
          other -> {nil, [error(path <> ".from", from_message(other)) | errors]}
        end

      {:ok, _correlation} ->
        {nil,
         [
           error(
             "response.external_correlation_id",
             "must be a mapping naming where the provider's message handle is"
           )
           | errors
         ]}

      :error ->
        {nil, errors}
    end
  end

  defp from_message(other) do
    "must be one of #{Enum.join(Enum.sort(Map.keys(@correlation_sources)), ", ")}, got " <>
      inspect(other)
  end

  defp correlation_from_body(correlation, path, errors) do
    errors = reject_unused(correlation, "header", path, errors)

    case correlation_path(Map.get(correlation, "path"), path <> ".path") do
      {:ok, segments} -> {%Correlation{from: :body, path: segments}, errors}
      {:error, correlation_errors} -> {nil, correlation_errors ++ errors}
    end
  end

  defp correlation_from_header(correlation, path, errors) do
    errors = reject_unused(correlation, "path", path, errors)

    case Map.get(correlation, "header") do
      header when is_binary(header) ->
        downcased = header |> String.trim() |> String.downcase()

        if Regex.match?(@header_name_regex, downcased) do
          {%Correlation{from: :header, header: downcased}, errors}
        else
          {nil, [error(path <> ".header", "is not a valid HTTP header name") | errors]}
        end

      nil ->
        {nil, [error(path <> ".header", "is required when from is header") | errors]}

      _other ->
        {nil, [error(path <> ".header", "must be a string") | errors]}
    end
  end

  defp reject_unused(correlation, key, path, errors) do
    if Map.has_key?(correlation, key) do
      [
        error(
          join(path, key),
          "does not apply when from is #{Map.get(correlation, "from")}; remove it"
        )
        | errors
      ]
    else
      errors
    end
  end

  defp correlation_path(nil, path) do
    {:error, [error(path, "is required when from is body; name the response field, e.g. id")]}
  end

  defp correlation_path(value, path) when is_binary(value) do
    value |> String.split(".") |> correlation_path(path)
  end

  defp correlation_path(value, path) when is_list(value) do
    cond do
      value == [] ->
        {:error, [error(path, "must name at least one response field")]}

      length(value) > @max_correlation_segments ->
        {:error, [error(path, "must be at most #{@max_correlation_segments} segments deep")]}

      not Enum.all?(value, &(is_binary(&1) and String.trim(&1) != "")) ->
        {:error,
         [
           error(
             path,
             "must be a dotted field path such as \"data.id\", or a list of field names. " <>
               "This is not JSONPath: a segment is a literal key."
           )
         ]}

      true ->
        {:ok, Enum.map(value, &String.trim/1)}
    end
  end

  defp correlation_path(_value, path) do
    {:error, [error(path, "must be a dotted field path or a list of field names")]}
  end

  # --- correlation extraction ----------------------------------------------

  defp correlation_value(%Correlation{from: :header, header: header}, response) do
    response
    |> Map.get(:headers, Map.get(response, "headers", %{}))
    |> header_value(header)
  end

  defp correlation_value(%Correlation{from: :body, path: path}, response) do
    response
    |> Map.get(:body, Map.get(response, "body"))
    |> fetch_path(path)
  end

  defp header_value(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      [value | _rest] -> value
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp header_value(_headers, _name), do: nil

  defp fetch_path(value, []), do: value

  defp fetch_path(value, [segment | rest]) when is_map(value) and not is_struct(value) do
    case Map.fetch(value, segment) do
      {:ok, child} -> fetch_path(child, rest)
      :error -> nil
    end
  end

  defp fetch_path(_value, _path), do: nil

  defp normalize_correlation_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, @max_correlation_bytes)
    end
  end

  defp normalize_correlation_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_correlation_id(_value), do: nil

  # --- canonical form -------------------------------------------------------

  defp request_to_map(%Request{} = request) do
    %{
      "method" => request.method |> Atom.to_string() |> String.upcase(),
      "url" => request.url,
      "headers" => request.headers,
      "body_format" => Atom.to_string(request.body_format),
      "body" => request.body
    }
  end

  defp correlation_to_map(nil), do: nil

  defp correlation_to_map(%Correlation{from: :body, path: path}) do
    %{"external_correlation_id" => %{"from" => "body", "path" => path}}
  end

  defp correlation_to_map(%Correlation{from: :header, header: header}) do
    %{"external_correlation_id" => %{"from" => "header", "header" => header}}
  end

  defp range_to_entry({code, code}), do: code
  defp range_to_entry(range), do: range_to_string(range)

  defp range_to_string({low, high}), do: "#{low}-#{high}"

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # --- shared helpers -------------------------------------------------------

  defp closed_keys(map, path, required, optional) do
    known = required ++ optional
    keys = map |> Map.keys() |> Enum.map(&stringify_key/1)

    unknown =
      keys
      |> Enum.reject(&(&1 in known))
      |> Enum.sort()
      |> Enum.map(fn key ->
        error(
          join(path, key),
          "is not a key of #{section(path)}; the document format is closed, and the keys " <>
            "here are #{Enum.join(Enum.sort(known), ", ")}"
        )
      end)

    missing =
      required
      |> Enum.reject(&(&1 in keys))
      |> Enum.sort()
      |> Enum.map(&error(join(path, &1), "is required"))

    unknown ++ missing
  end

  defp section(""), do: "a provider definition"
  defp section(path), do: path

  defp take_atom_list(document, key, allowed) do
    case Map.fetch(document, key) do
      {:ok, values} when is_list(values) ->
        {parsed, errors} =
          Enum.reduce(values, {[], []}, fn value, {parsed, errors} ->
            case match_atom(value, allowed) do
              {:ok, atom} ->
                if atom in parsed do
                  {parsed, errors ++ [{:duplicate, "lists #{inspect(atom)} more than once"}]}
                else
                  {parsed ++ [atom], errors}
                end

              :error ->
                {parsed,
                 errors ++
                   [{:unknown, "#{inspect(value)} is not one of #{inspect(Enum.sort(allowed))}"}]}
            end
          end)

        if errors == [], do: {:ok, parsed}, else: {:error, errors}

      {:ok, _values} ->
        {:error, [{:unknown, "must be a list of #{inspect(Enum.sort(allowed))}"}]}

      :error ->
        :missing
    end
  end

  # Atoms are matched by comparing against the compile-time allowlist, never
  # created from document content (Iron Laws).
  defp match_atom(value, allowed) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> :error
      atom -> {:ok, atom}
    end
  end

  defp match_atom(value, allowed) when is_atom(value) and not is_nil(value) do
    if value in allowed, do: {:ok, value}, else: :error
  end

  defp match_atom(_value, _allowed), do: :error

  defp in_ranges?(ranges, status) do
    Enum.any?(ranges, fn {low, high} -> status >= low and status <= high end)
  end

  defp expand(ranges) do
    ranges
    |> Enum.flat_map(fn {low, high} -> Enum.to_list(low..high) end)
    |> MapSet.new()
  end

  defp join("", key), do: key
  defp join(path, key), do: path <> "." <> key

  defp error(path, message), do: %{path: path, message: message}

  defp sort_errors(errors) do
    errors
    |> Enum.uniq()
    |> Enum.sort_by(fn %{path: path, message: message} -> {path, message} end)
  end

  defp presence(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp stringify(%{} = map) when not is_struct(map) do
    Map.new(map, fn {key, value} -> {stringify_key(key), stringify(value)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp stringify_key(key) when is_binary(key), do: key
  defp stringify_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_key(key) when is_number(key), do: to_string(key)

  # Anything else fails the closed-key check with its own inspected form, which
  # is the actionable outcome; `to_string/1` would raise instead.
  defp stringify_key(key), do: inspect(key)

  defp check_input_size(binary) do
    if byte_size(binary) > @max_input_bytes do
      {:error,
       [
         error(
           "document",
           "is larger than #{@max_input_bytes} bytes; a provider definition is a few kilobytes"
         )
       ]}
    else
      :ok
    end
  end

  defp bounded_yaml(binary) do
    parent = self()
    token = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{
          size: @yaml_heap_words,
          kill: true,
          error_logger: false
        })

        send(parent, {token, YamlElixir.read_from_string(binary)})
      end)

    receive do
      {^token, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, :killed} ->
        {:error, :bounded}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, reason}
    after
      @yaml_timeout_ms ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        {:error, :bounded}
    end
  end

  defp message(%YamlElixir.ParsingError{} = exception), do: Exception.message(exception)
  defp message(exception) when is_exception(exception), do: Exception.message(exception)
  defp message(reason), do: inspect(reason)
end
