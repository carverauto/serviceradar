defmodule ServiceRadarWebNGWeb.Settings.NotificationsLive.ProviderUpload do
  @moduledoc """
  The declarative provider upload form: parse, validate, preview, and the
  attribute maps a `NotificationProvider` row is written from (tasks 2.3.1,
  2.3.2).

  This is the module that has to make the tier's claim true. Design D2 puts
  roughly 85% of notification destinations in one sentence - "POST this JSON body
  to this URL with these headers" - and the declarative tier's promise is that an
  operator adds one of those **by uploading a document: no code, no release, no
  Wasm toolchain**. Everything here is in service of the moment an operator
  pastes a document and presses save.

  ## The validator is the only source of error text

  `ServiceRadar.Notifications.Declarative.Definition.parse/1` returns EVERY
  problem a document has, each carrying the path it is at
  (`request.headers.authorization`, `config_schema.properties.api_key`) and a
  sentence that says what to do about it. Nothing in this module invents,
  summarises, or collapses those messages, and there is deliberately no generic
  "invalid document" branch: an operator writing a provider sees only what the
  validator tells them, and a notification provider is exercised for the first
  time during an incident.

  ## The preview substitutes placeholders, never values

  `preview/1` builds the request through
  `ServiceRadar.Notifications.Transports.Declarative.render_request/2` - the same
  function `deliver/2` renders with, over the same restricted substitution engine
  every notification body uses - against a context in which every legal path
  resolves to a visible marker of itself: `alert.title` renders as
  `<alert.title>`, `config.webhook_url` as `<config.webhook_url>`. Rendering
  through the engine rather than beside it is what keeps a preview from
  disagreeing with what would be sent.

  Two reasons it is placeholders rather than sample data. A channel does not
  exist yet at upload time, so there are no real `config.*` values to show; and a
  preview that rendered a plausible-looking value where a secret goes would be
  training an operator to expect one. `secrets.*` markers are placeholders in the
  strictest sense - no secret is resolved, read, or rendered here, and this
  module never touches `Credentials.SecretBroker`.

  What the preview is actually FOR is the three mistakes a validator cannot
  catch: a substitution that landed in the wrong field, a body whose shape is not
  what the author drew, and a YAML document whose anchors silently collapsed
  (`yamerl` does not resolve aliases, so `*ref` decodes to the anchored node's
  first scalar - the preview is where that becomes visible).

  ## Versioning

  `create_attrs/1` and `update_attrs/2` are the only places a definition becomes
  provider attributes, so an upload and a rollback write the same shape. An
  upload never rewrites history: it writes `definition_version` one higher than
  the current row, because `NotificationDelivery.provider_version` records the
  version that rendered each delivery and a superseded version has to stay
  identifiable on rows that already reference it.

  `source` is set to `:uploaded` on every save, including a save over a seeded
  catalog entry. That is the provenance the Providers table shows, and it has a
  second effect worth stating: `source` and `definition_version` are both
  `ServiceRadar.Notifications.ProviderSeeder` managed fields, so an upload over a
  managed row diverges its `template_fingerprint` and the next release's
  reconciliation leaves the operator's document alone.

  ## Purity

  Pure. No database, no clock, no network, no `String.to_atom/1`, no `raw/1`
  content. Its tests run `async: true`.
  """

  alias ServiceRadar.Notifications.Declarative.Definition
  alias ServiceRadar.Notifications.Template.Syntax
  alias ServiceRadar.Notifications.Transports.Declarative

  # The cap `Definition` itself enforces. Refusing here as well keeps a document
  # that could never parse out of socket assigns, where it would be held for the
  # lifetime of the editor.
  @max_document_bytes 64 * 1024

  # A preview is a reading aid, not a second rendering of the document. Past this
  # many body lines the point is made and the rest is scroll.
  @max_preview_body_bytes 8_000

  @type error :: %{path: String.t(), message: String.t()}

  @type form :: %{
          mode: :new | :replace,
          provider_id: String.t() | nil,
          provider_key: String.t() | nil,
          params: %{String.t() => String.t()},
          errors: [error()],
          definition: Definition.t() | nil,
          preview: map() | nil,
          error: String.t() | nil
        }

  @doc "The document size cap, in bytes."
  @spec max_document_bytes() :: pos_integer()
  def max_document_bytes, do: @max_document_bytes

  @doc "An empty upload form."
  @spec blank_form() :: form()
  def blank_form do
    %{
      mode: :new,
      provider_id: nil,
      provider_key: nil,
      params: %{"document" => ""},
      errors: [],
      definition: nil,
      preview: nil,
      error: nil
    }
  end

  @doc """
  An upload form seeded with an existing declarative provider's stored document.

  The canonical stored form is what is offered for editing rather than the bytes
  an operator once pasted: it is the document that was validated, and it is the
  one the engine reads.
  """
  @spec form_for(map()) :: form()
  def form_for(%{provider_type: :declarative} = provider) do
    blank_form()
    |> Map.put(:mode, :replace)
    |> Map.put(:provider_id, to_string(provider.id))
    |> Map.put(:provider_key, provider.provider_key)
    |> Map.put(:params, %{"document" => document_text(provider.definition)})
    |> validate()
  end

  @doc """
  Merges submitted params into a form.

  A document past `max_document_bytes/0` is refused rather than stored: the
  previous text is kept so nothing an operator typed disappears, and the refusal
  is reported the same way a validation error is.
  """
  @spec merge(form() | nil, term()) :: form()
  def merge(nil, params), do: merge(blank_form(), params)

  def merge(form, params) when is_map(params) do
    case document_param(params) do
      {:ok, document} ->
        form
        |> Map.put(:params, Map.put(form.params, "document", document))
        |> Map.put(:error, nil)

      {:error, message} ->
        Map.put(form, :error, message)
    end
  end

  def merge(form, _params), do: form

  @doc """
  Parses and validates the form's document.

  Sets `:definition` and `:preview` when the document is admissible, and
  `:errors` - the validator's own list, unaltered - when it is not. A blank
  document is neither: there is nothing to report yet.
  """
  @spec validate(form()) :: form()
  def validate(form) do
    case String.trim(document(form)) do
      "" ->
        form
        |> Map.put(:errors, [])
        |> Map.put(:definition, nil)
        |> Map.put(:preview, nil)

      _document ->
        do_validate(form)
    end
  end

  defp do_validate(form) do
    case Definition.parse(document(form)) do
      {:ok, definition} ->
        form
        |> Map.put(:errors, [])
        |> Map.put(:definition, definition)
        |> put_preview(definition)

      {:error, errors} ->
        form
        |> Map.put(:errors, errors)
        |> Map.put(:definition, nil)
        |> Map.put(:preview, nil)
    end
  end

  defp put_preview(form, definition) do
    case preview(definition) do
      {:ok, preview} -> form |> Map.put(:preview, preview) |> Map.put(:error, nil)
      {:error, message} -> form |> Map.put(:preview, nil) |> Map.put(:error, message)
    end
  end

  @doc "The document text held by a form."
  @spec document(form()) :: String.t()
  def document(%{params: params}), do: Map.get(params, "document", "")
  def document(_form), do: ""

  @doc """
  The attributes a new `:declarative` provider row is created from.

  `provider_key` and `provider_type` are create-only on the resource - changing
  the tier of a live provider would invalidate every channel configured against
  its `config_schema` - so they appear here and not in `update_attrs/2`.
  """
  @spec create_attrs(Definition.t()) :: map()
  def create_attrs(%Definition{} = definition) do
    definition
    |> shared_attrs(1)
    |> Map.put(:provider_key, definition.key)
    |> Map.put(:provider_type, :declarative)
  end

  @doc """
  The attributes an existing `:declarative` provider row is updated with.

  `current_version` is the row's `definition_version`; the new version is one
  higher. A rollback uses this too, so restoring an older document is an ordinary
  new version rather than an edit of a version deliveries already point at.
  """
  @spec update_attrs(Definition.t(), term()) :: map()
  def update_attrs(%Definition{} = definition, current_version) do
    shared_attrs(definition, next_version(current_version))
  end

  @doc "The version number an upload over `current_version` produces."
  @spec next_version(term()) :: pos_integer()
  def next_version(current_version) when is_integer(current_version) and current_version > 0 do
    current_version + 1
  end

  def next_version(_current_version), do: 1

  defp shared_attrs(%Definition{} = definition, version) do
    %{
      display_name: definition.display_name,
      description: definition.description,
      icon: definition.icon,
      config_schema: definition.config_schema,
      capabilities: definition.capabilities,
      supported_routes: definition.routes,
      payload_formats: definition.payload_formats,
      definition: Definition.to_map(definition),
      definition_version: version,
      source: :uploaded
    }
  end

  # --- preview ---------------------------------------------------------------

  @doc """
  The request this document would issue, with every substitution point marked.

  Rendered by `ServiceRadar.Notifications.Transports.Declarative.render_request/2`
  - the same function `deliver/2` renders with - so the preview cannot disagree
  with what would be sent. This module supplies only the context, and every value
  in it is a marker naming the path it stands for; see the moduledoc for why the
  preview shows placeholders rather than values.
  """
  @spec preview(Definition.t()) :: {:ok, map()} | {:error, String.t()}
  def preview(%Definition{} = definition) do
    case Declarative.render_request(definition, placeholder_context(definition)) do
      {:ok, rendered} ->
        {:ok,
         %{
           method: rendered.method |> Atom.to_string() |> String.upcase(),
           url: rendered.url,
           headers: rendered.headers |> Map.to_list() |> Enum.sort_by(&elem(&1, 0)),
           body_format: rendered.body_format,
           body: display_body(rendered.body_format, rendered.body),
           fields: schema_fields(definition),
           success: Enum.map_join(definition.success_status, ", ", &range_label/1),
           retryable: Enum.map_join(definition.retryable_status, ", ", &range_label/1),
           unresolved: rendered.unresolved
         }}

      {:error, errors} ->
        {:error,
         "this document parsed but could not be rendered: " <>
           Enum.map_join(errors, "; ", fn %{field: field, message: message} ->
             "#{field} #{message}"
           end)}
    end
  end

  defp display_body(:text, body) when is_binary(body), do: truncate(body)
  defp display_body(_format, body), do: body |> encode() |> truncate()

  defp encode(term) do
    case Jason.encode(term, pretty: true) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> inspect(term)
    end
  end

  defp truncate(value) when is_binary(value) do
    if byte_size(value) > @max_preview_body_bytes do
      binary_part(value, 0, @max_preview_body_bytes) <> "\n..."
    else
      value
    end
  end

  # NOTE: truncate/1 takes binaries only. display_body/2 normalizes every
  # non-binary preview through encode/1 (Jason or inspect) before calling it,
  # so truncate/1 needs no to_string/1 fallback.

  # Every path a template in this document may address, resolved to a marker
  # naming itself. Built from the closed catalog plus the two namespaces the
  # document's own `config_schema` declares - the same list the validator
  # admitted the templates against, so the preview cannot render a path the
  # validator refused, or refuse one it allowed.
  defp placeholder_context(definition) do
    definition
    |> addressable_paths()
    |> Kernel.++(Syntax.variable_catalog())
    |> Enum.reduce(%{}, fn path, acc ->
      put_path(acc, String.split(path, "."), "<" <> path <> ">")
    end)
  end

  defp addressable_paths(definition) do
    Definition.config_paths(definition) ++ Definition.secret_paths(definition)
  end

  defp put_path(map, [key], value), do: Map.put(map, key, value)

  defp put_path(map, [key | rest], value) do
    child = Map.get(map, key)
    child = if is_map(child), do: child, else: %{}

    Map.put(map, key, put_path(child, rest, value))
  end

  # The channel form an operator will see, taken from the document's own
  # `config_schema`. A provider describes its UI declaratively; this is that
  # description read back, never markup carried in the document.
  defp schema_fields(%Definition{config_schema: schema}) do
    required = required_fields(schema)
    secrets = secret_fields(schema)

    schema
    |> properties()
    |> Enum.sort_by(fn {name, _property} -> name end)
    |> Enum.map(fn {name, property} ->
      %{
        name: name,
        title: title(property, name),
        type: string_or_nil(Map.get(property, "type")),
        required?: name in required,
        secret?: name in secrets
      }
    end)
  end

  defp properties(schema) when is_map(schema) do
    case Map.get(schema, "properties") do
      properties when is_map(properties) and not is_struct(properties) -> properties
      _other -> %{}
    end
  end

  defp properties(_schema), do: %{}

  defp required_fields(schema) when is_map(schema) do
    case Map.get(schema, "required") do
      required when is_list(required) -> Enum.filter(required, &is_binary/1)
      _other -> []
    end
  end

  defp required_fields(_schema), do: []

  defp secret_fields(schema) when is_map(schema) do
    schema
    |> properties()
    |> Enum.filter(fn {_name, property} ->
      is_map(property) and Map.get(property, "secretRef") == true
    end)
    |> Enum.map(fn {name, _property} -> name end)
  end

  defp secret_fields(_schema), do: []

  defp title(property, name) when is_map(property) do
    case Map.get(property, "title") do
      title when is_binary(title) and title != "" -> title
      _other -> name
    end
  end

  defp title(_property, name), do: name

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp range_label({code, code}), do: to_string(code)
  defp range_label({low, high}), do: "#{low}-#{high}"

  # --- document text ---------------------------------------------------------

  @doc """
  A stored definition rendered back as an editable document.

  JSON rather than YAML: `Jason` is already the canonical encoder for the stored
  `jsonb` form, and round-tripping through it cannot introduce a construct the
  document did not have.
  """
  @spec document_text(term()) :: String.t()
  def document_text(definition) when is_map(definition) and not is_struct(definition) do
    case Jason.encode(definition, pretty: true) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> ""
    end
  end

  def document_text(_definition), do: ""

  defp document_param(params) do
    case Map.get(params, "document") do
      nil ->
        {:ok, ""}

      document when is_binary(document) ->
        if byte_size(document) > @max_document_bytes do
          {:error,
           "that document is larger than #{@max_document_bytes} bytes; a provider definition " <>
             "is a few kilobytes, and one this size could not be parsed"}
        else
          {:ok, document}
        end

      _other ->
        {:ok, ""}
    end
  end
end
