defmodule ServiceRadarWebNGWeb.PluginConfigForm do
  @moduledoc false

  use Phoenix.Component

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadar.Plugins.SecretRefs

  attr(:schema, :map, default: %{})
  attr(:params, :map, default: %{})
  attr(:base_name, :string, default: "params")
  attr(:docs_url, :string, default: nil)

  attr(:credential_coverage, :map,
    default: nil,
    doc:
      "Matching-rule status for credential-materialized fields: " <>
        "%{state: :covered | :uncovered, provider:, purpose:, rules: [names]} or nil when unknown."
  )

  def plugin_config_fields(assigns) do
    schema = normalize_schema(assigns.schema)
    params = normalize_params(assigns.params)

    # Fields provided by credential-rule materialization render as informational
    # rows (with live rule-coverage status), never as hidden or ordinary inputs.
    {materialized_properties, properties} =
      schema
      |> Map.get("properties", %{})
      |> Enum.split_with(fn {name, prop} ->
        credential_materialized?(prop) and not assignment_secret_property?(name)
      end)

    properties =
      Enum.reject(properties, fn {name, prop} ->
        internal_property?(name, prop) or assignment_secret_property?(name)
      end)

    # Split into the primary fields (shown inline) and advanced fields (collapsed by
    # default). Advanced fields are opt-in extras; a schema with no advanced hints renders
    # exactly as before (everything inline, no collapse).
    {advanced_properties, basic_properties} =
      Enum.split_with(properties, fn {_name, prop} -> advanced?(prop) end)

    required = Map.get(schema, "required", [])
    docs_url = docs_url(assigns.docs_url, schema)

    assigns =
      assigns
      |> assign(:schema, schema)
      |> assign(:params, params)
      |> assign(:materialized_properties, materialized_properties)
      |> assign(:basic_properties, basic_properties)
      |> assign(:advanced_properties, advanced_properties)
      |> assign(:required, required)
      |> assign(:docs_url, docs_url)

    ~H"""
    <div class="space-y-4">
      <div
        :if={@docs_url}
        class="rounded-lg border border-info/20 bg-info/10 p-3 text-sm text-sr-ink/90"
      >
        Need help with these settings?
        <a
          class="text-sr-brand hover:underline"
          href={@docs_url}
          target="_blank"
          rel="noopener noreferrer"
        >
          Open the configuration guide
        </a>
      </div>

      <.credential_materialized_field
        :for={{name, prop} <- @materialized_properties}
        name={name}
        prop={prop}
        coverage={@credential_coverage}
      />

      <.config_field
        :for={{name, prop} <- @basic_properties}
        name={name}
        prop={prop}
        required={@required}
        params={@params}
        base_name={@base_name}
      />

      <details
        :if={@advanced_properties != []}
        id={advanced_details_id(@base_name)}
        phx-hook="DetailsState"
        class="rounded-lg border border-sr-line bg-sr-subtle/40"
      >
        <summary class="cursor-pointer select-none px-3 py-2 text-sm font-medium text-sr-ink/90">
          Advanced settings (optional)
        </summary>
        <div class="space-y-4 p-3 pt-1">
          <.config_field
            :for={{name, prop} <- @advanced_properties}
            name={name}
            prop={prop}
            required={@required}
            params={@params}
            base_name={@base_name}
          />
        </div>
      </details>
    </div>
    """
  end

  attr(:name, :string, required: true)
  attr(:prop, :map, required: true)
  attr(:coverage, :map, default: nil)

  def credential_materialized_field(assigns) do
    assigns = assign(assigns, :description, Map.get(assigns.prop, "description"))

    ~H"""
    <div
      class="rounded-lg border border-sr-line bg-sr-subtle/40 p-3 space-y-1"
      data-credential-materialized={@name}
    >
      <div class="flex flex-wrap items-center gap-2">
        <span class="text-sm font-medium">{Map.get(@prop, "title") || @name}</span>
        <.ui_badge size="sm" variant="ghost">Provided by credential rules</.ui_badge>
      </div>
      <p :if={is_binary(@description) and @description != ""} class="text-xs text-sr-muted">
        {@description}
      </p>
      <%= case coverage_state(@coverage) do %>
        <% :covered -> %>
          <p class="text-xs text-success">
            Rule {coverage_rule_names(@coverage)} matches this agent.
          </p>
        <% :uncovered -> %>
          <p class="text-xs text-warning">
            No enabled {coverage_scope_label(@coverage)} credential rule matches this agent —
            this input will be missing at runtime until a matching rule is enabled.
          </p>
        <% _ -> %>
          <p class="text-xs text-sr-muted">
            Value is materialized per target by credential rules at runtime.
          </p>
      <% end %>
    </div>
    """
  end

  attr(:name, :string, required: true)
  attr(:prop, :map, required: true)
  attr(:required, :list, default: [])
  attr(:params, :map, default: %{})
  attr(:base_name, :string, default: "params")

  attr(:credentials, :list,
    default: [],
    doc: "Reusable credentials offered for secretRef fields. Empty renders raw entry only."
  )

  def config_field(assigns) do
    ~H"""
    <div class="space-y-2">
      <label class="flex items-center justify-between gap-2">
        <span class="text-sm font-medium text-sr-ink">
          {Map.get(@prop, "title") || @name}
          <%= if @name in @required do %>
            <span class="text-error">*</span>
          <% end %>
        </span>
      </label>

      <%= case input_type(@prop) do %>
        <% :secret -> %>
          <%= if @credentials != [] do %>
            <select
              name={input_name(@base_name, SecretRefs.credential_select_key(@name))}
              class={ui_field_class(class: "w-full")}
            >
              <option value="">— enter a value below —</option>
              <option
                :for={secret <- compatible_credentials(@credentials, @prop)}
                value={SecretRefs.network_credential_ref(secret.id)}
                selected={SecretRefs.network_credential_ref(secret.id) == value_for(@params, @name)}
              >
                {secret.name} ({secret.provider})
              </option>
            </select>
            <p class="text-xs text-sr-muted">
              <%= if credential_kind(@prop) do %>
                Reusable {credential_kind(@prop)} credentials from the shared inventory.
              <% else %>
                Reusable credentials from the shared inventory. This field declares no
                credential kind, so all are listed.
              <% end %>
            </p>
          <% end %>
          <input
            type="password"
            name={input_name(@base_name, @name)}
            value=""
            class={ui_field_class(class: "w-full")}
            placeholder={secret_placeholder(@params, @name)}
          />
          <%= if current_secret_ref(@params, @name) do %>
            <p class="text-xs text-sr-muted">
              Stored secret ref: {current_secret_ref(@params, @name)}
            </p>
          <% end %>
        <% :select -> %>
          <select
            name={input_name(@base_name, @name)}
            class={ui_field_class(class: "w-full")}
          >
            <%= for option <- Map.get(@prop, "enum", []) do %>
              <option
                value={option}
                selected={option == value_for(@params, @name)}
              >
                {option}
              </option>
            <% end %>
          </select>
        <% :checkbox -> %>
          <div class="flex items-center gap-2">
            <input type="hidden" name={input_name(@base_name, @name)} value="false" />
            <input
              type="checkbox"
              name={input_name(@base_name, @name)}
              value="true"
              class={ui_checkbox_class()}
              checked={truthy?(value_for(@params, @name))}
            />
            <span class="text-xs text-sr-muted">Enable</span>
          </div>
        <% :textarea -> %>
          <textarea
            name={input_name(@base_name, @name)}
            class={ui_field_class(mono: true, class: "w-full min-h-[100px] py-2.5 text-xs")}
            placeholder={array_placeholder(@prop)}
          ><%= value_for(@params, @name) %></textarea>
        <% :number -> %>
          <input
            type="number"
            name={input_name(@base_name, @name)}
            value={value_for(@params, @name)}
            min={Map.get(@prop, "minimum")}
            max={Map.get(@prop, "maximum")}
            step={number_step(@prop)}
            class={ui_field_class(class: "w-full")}
          />
        <% :text -> %>
          <input
            type={text_input_type(@prop)}
            name={input_name(@base_name, @name)}
            value={value_for(@params, @name)}
            minlength={Map.get(@prop, "minLength")}
            maxlength={Map.get(@prop, "maxLength")}
            pattern={html_pattern(Map.get(@prop, "pattern"))}
            class={ui_field_class(class: "w-full")}
          />
      <% end %>

      <%= if is_binary(Map.get(@prop, "description")) and Map.get(@prop, "description") != "" do %>
        <p class="text-xs text-sr-muted">{Map.get(@prop, "description")}</p>
      <% end %>
    </div>
    """
  end

  defp normalize_schema(schema) when is_map(schema) do
    schema
    |> stringify_keys()
    |> Map.put_new("properties", %{})
  end

  defp normalize_schema(_), do: %{"properties" => %{}}

  defp normalize_params(params) when is_map(params), do: stringify_keys(params)
  defp normalize_params(_), do: %{}

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp input_name(base, name), do: "#{base}[#{name}]"

  defp input_type(%{"enum" => enum}) when is_list(enum) and enum != [], do: :select

  defp input_type(prop) when is_map(prop) do
    if secret_ref?(prop), do: :secret, else: input_type_from_type(prop)
  end

  defp input_type(_), do: :text

  defp input_type_from_type(%{"type" => "boolean"}), do: :checkbox
  defp input_type_from_type(%{"type" => "integer"}), do: :number
  defp input_type_from_type(%{"type" => "number"}), do: :number
  defp input_type_from_type(%{"type" => "array"}), do: :textarea
  defp input_type_from_type(_), do: :text

  # HTML number inputs default to step=1. JSON Schema `number` values are not
  # integers, so omitting the step rejects perfectly valid defaults such as 0.5
  # before the form ever reaches server-side schema validation.
  defp number_step(%{"multipleOf" => step}) when is_number(step) and step > 0, do: step
  defp number_step(%{"type" => "integer"}), do: 1
  defp number_step(%{"type" => "number"}), do: "any"
  defp number_step(_prop), do: nil

  defp internal_property?(name, %{} = prop) do
    Map.get(prop, "x-serviceradar-internal") == true or
      Map.get(prop, "x-serviceradar-ui-hidden") == true or
      name in ["console", "credential_broker", "credential_rule_id"]
  end

  defp internal_property?(_name, _), do: false

  defp assignment_secret_property?(name) when is_binary(name) do
    name in [
      "password",
      "api_key",
      "cookie",
      "username",
      "password_secret_ref",
      "api_key_secret_ref",
      "token_secret"
    ]
  end

  defp assignment_secret_property?(_name), do: false

  defp advanced?(%{} = prop), do: Map.get(prop, "x-serviceradar-ui-advanced") == true
  defp advanced?(_), do: false

  defp advanced_details_id(base_name) do
    slug =
      base_name
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    slug <> "-advanced-settings"
  end

  defp credential_materialized?(%{} = prop) do
    Map.get(prop, "x-serviceradar-credential-materialized") == true
  end

  defp credential_materialized?(_), do: false

  defp coverage_state(%{state: state}) when state in [:covered, :uncovered], do: state
  defp coverage_state(%{"state" => state}) when state in [:covered, :uncovered], do: state
  defp coverage_state(_coverage), do: :unknown

  defp coverage_rule_names(coverage) when is_map(coverage) do
    coverage
    |> Map.get(:rules, Map.get(coverage, "rules", []))
    |> case do
      [] -> "(unnamed)"
      names -> Enum.join(names, ", ")
    end
  end

  defp coverage_rule_names(_coverage), do: "(unnamed)"

  defp coverage_scope_label(coverage) when is_map(coverage) do
    provider = Map.get(coverage, :provider, Map.get(coverage, "provider"))
    purpose = Map.get(coverage, :purpose, Map.get(coverage, "purpose"))

    [provider, purpose]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join("/", &to_string/1)
  end

  defp coverage_scope_label(_coverage), do: ""

  defp docs_url(explicit_url, schema) do
    Enum.find(
      [explicit_url, Map.get(schema, "x-serviceradar-docs-url"), fallback_docs_url(schema)],
      &safe_docs_url?/1
    )
  end

  defp safe_docs_url?(value) when is_binary(value) do
    uri = URI.parse(value)
    uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and is_nil(uri.userinfo)
  end

  defp safe_docs_url?(_value), do: false

  defp fallback_docs_url(%{"title" => "Proxmox Console"}) do
    "https://docs.serviceradar.cloud/docs/proxmox#console-access"
  end

  defp fallback_docs_url(_schema) do
    nil
  end

  defp text_input_type(%{"format" => "uri"}), do: "url"
  defp text_input_type(%{"format" => "email"}), do: "email"
  defp text_input_type(_), do: "text"

  # JSON Schema `pattern` is unanchored unless it includes ^/$. HTML `pattern`
  # is always a full-string match (`^(?:...)$`). Copying `^https://` verbatim
  # therefore rejects every real URL: the browser requires the entire value to
  # be exactly "https://". Convert prefix/suffix/unanchored patterns so they
  # mean the same thing in the browser as they do in the schema.
  defp html_pattern(pattern) when is_binary(pattern) and pattern != "" do
    starts? = String.starts_with?(pattern, "^")
    ends? = String.ends_with?(pattern, "$")

    inner =
      pattern
      |> then(&if(starts?, do: String.replace_prefix(&1, "^", ""), else: &1))
      |> then(&if(ends?, do: String.replace_suffix(&1, "$", ""), else: &1))

    cond do
      starts? and ends? -> inner
      starts? -> inner <> ".*"
      ends? -> ".*" <> inner
      true -> ".*" <> inner <> ".*"
    end
  end

  defp html_pattern(_pattern), do: nil

  defp value_for(params, name) do
    value = Map.get(params, name)

    cond do
      is_list(value) and Enum.any?(value, &is_map/1) -> Jason.encode!(value, pretty: true)
      is_list(value) -> Enum.join(value, "\n")
      is_map(value) -> Jason.encode!(value)
      true -> value || ""
    end
  end

  defp truthy?(value) when is_boolean(value), do: value
  defp truthy?(value) when is_binary(value), do: String.downcase(value) == "true"
  defp truthy?(_), do: false

  defp secret_ref?(prop), do: Map.get(prop, "secretRef") == true

  # The optional `credentialKind` hint from the package's config schema. Absent
  # on the 17 packages already shipping `secretRef`, so nil means "unfiltered"
  # rather than "nothing matches" -- filtering an unhinted field to zero options
  # would hide the inventory from exactly the fields that predate the hint.
  defp credential_kind(prop) when is_map(prop) do
    case Map.get(prop, "credentialKind") do
      kind when is_binary(kind) and kind != "" -> kind
      _ -> nil
    end
  end

  defp credential_kind(_prop), do: nil

  defp compatible_credentials(credentials, prop) do
    case credential_kind(prop) do
      nil -> credentials
      kind -> Enum.filter(credentials, &(to_string(&1.credential_kind) == kind))
    end
  end

  defp current_secret_ref(params, name) do
    case Map.get(params, name) do
      value when is_binary(value) ->
        if SecretRefs.secret_ref?(value), do: value

      _ ->
        nil
    end
  end

  defp secret_placeholder(params, name) do
    if current_secret_ref(params, name) do
      "Leave blank to keep existing secret"
    else
      ""
    end
  end

  defp array_placeholder(prop) do
    case get_in(prop, ["items", "type"]) do
      "string" -> "one per line"
      "integer" -> "e.g. 1\n2\n3"
      "number" -> "e.g. 1.5\n2.5"
      _ -> "one per line"
    end
  end
end
