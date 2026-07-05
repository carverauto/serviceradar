defmodule ServiceRadarWebNGWeb.PluginConfigForm do
  @moduledoc false

  use Phoenix.Component

  attr :schema, :map, default: %{}
  attr :params, :map, default: %{}
  attr :base_name, :string, default: "params"

  attr :credential_coverage, :map,
    default: nil,
    doc:
      "Matching-rule status for credential-materialized fields: " <>
        "%{state: :covered | :uncovered, provider:, purpose:, rules: [names]} or nil when unknown."

  def plugin_config_fields(assigns) do
    schema = normalize_schema(assigns.schema)
    params = normalize_params(assigns.params)

    # Fields provided by credential-rule materialization render as informational
    # rows (with live rule-coverage status), never as hidden or ordinary inputs.
    {materialized_properties, properties} =
      schema
      |> Map.get("properties", %{})
      |> Enum.split_with(fn {_name, prop} -> credential_materialized?(prop) end)

    properties = Enum.reject(properties, fn {name, prop} -> internal_property?(name, prop) end)

    # Split into the primary fields (shown inline) and advanced fields (collapsed by
    # default). Advanced fields are opt-in extras; a schema with no advanced hints renders
    # exactly as before (everything inline, no collapse).
    {advanced_properties, basic_properties} =
      Enum.split_with(properties, fn {_name, prop} -> advanced?(prop) end)

    required = Map.get(schema, "required", [])

    assigns =
      assigns
      |> assign(:schema, schema)
      |> assign(:params, params)
      |> assign(:materialized_properties, materialized_properties)
      |> assign(:basic_properties, basic_properties)
      |> assign(:advanced_properties, advanced_properties)
      |> assign(:required, required)
      |> assign(:docs_url, docs_url(schema))

    ~H"""
    <div class="space-y-4">
      <div
        :if={@docs_url}
        class="rounded-lg border border-info/20 bg-info/10 p-3 text-sm text-base-content/80"
      >
        Need help with these settings?
        <a class="link link-primary" href={@docs_url} target="_blank" rel="noopener noreferrer">
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
        class="rounded-lg border border-base-300 bg-base-200/40"
      >
        <summary class="cursor-pointer select-none px-3 py-2 text-sm font-medium text-base-content/80">
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

  attr :name, :string, required: true
  attr :prop, :map, required: true
  attr :coverage, :map, default: nil

  def credential_materialized_field(assigns) do
    assigns = assign(assigns, :description, Map.get(assigns.prop, "description"))

    ~H"""
    <div
      class="rounded-lg border border-base-300 bg-base-200/40 p-3 space-y-1"
      data-credential-materialized={@name}
    >
      <div class="flex flex-wrap items-center gap-2">
        <span class="text-sm font-medium">{Map.get(@prop, "title") || @name}</span>
        <span class="badge badge-ghost badge-sm">Provided by credential rules</span>
      </div>
      <p :if={is_binary(@description) and @description != ""} class="text-xs text-base-content/60">
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
          <p class="text-xs text-base-content/60">
            Value is materialized per target by credential rules at runtime.
          </p>
      <% end %>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :prop, :map, required: true
  attr :required, :list, default: []
  attr :params, :map, default: %{}
  attr :base_name, :string, default: "params"

  def config_field(assigns) do
    ~H"""
    <div class="space-y-2">
      <label class="label">
        <span class="label-text">
          {Map.get(@prop, "title") || @name}
          <%= if @name in @required do %>
            <span class="text-error">*</span>
          <% end %>
        </span>
      </label>

      <%= case input_type(@prop) do %>
        <% :secret -> %>
          <input
            type="password"
            name={input_name(@base_name, @name)}
            value=""
            class="input input-bordered w-full"
            placeholder={secret_placeholder(@params, @name)}
          />
          <%= if current_secret_ref(@params, @name) do %>
            <p class="text-xs text-base-content/60">
              Stored secret ref: {current_secret_ref(@params, @name)}
            </p>
          <% end %>
        <% :select -> %>
          <select
            name={input_name(@base_name, @name)}
            class="select select-bordered w-full"
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
              class="checkbox checkbox-sm"
              checked={truthy?(value_for(@params, @name))}
            />
            <span class="text-xs text-base-content/60">Enable</span>
          </div>
        <% :textarea -> %>
          <textarea
            name={input_name(@base_name, @name)}
            class="textarea textarea-bordered w-full font-mono text-xs min-h-[100px]"
            placeholder={array_placeholder(@prop)}
          ><%= value_for(@params, @name) %></textarea>
        <% :number -> %>
          <input
            type="number"
            name={input_name(@base_name, @name)}
            value={value_for(@params, @name)}
            min={Map.get(@prop, "minimum")}
            max={Map.get(@prop, "maximum")}
            class="input input-bordered w-full"
          />
        <% :text -> %>
          <input
            type={text_input_type(@prop)}
            name={input_name(@base_name, @name)}
            value={value_for(@params, @name)}
            minlength={Map.get(@prop, "minLength")}
            maxlength={Map.get(@prop, "maxLength")}
            pattern={Map.get(@prop, "pattern")}
            class="input input-bordered w-full"
          />
      <% end %>

      <%= if is_binary(Map.get(@prop, "description")) and Map.get(@prop, "description") != "" do %>
        <p class="text-xs text-base-content/60">{Map.get(@prop, "description")}</p>
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

  defp internal_property?(name, %{} = prop) do
    Map.get(prop, "x-serviceradar-internal") == true or
      Map.get(prop, "x-serviceradar-ui-hidden") == true or
      name in ["console", "credential_broker", "credential_rule_id"]
  end

  defp internal_property?(_name, _), do: false

  defp advanced?(%{} = prop), do: Map.get(prop, "x-serviceradar-ui-advanced") == true
  defp advanced?(_), do: false

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

  defp docs_url(schema) do
    schema
    |> Map.get("x-serviceradar-docs-url")
    |> case do
      value when is_binary(value) and value != "" -> value
      _ -> fallback_docs_url(schema)
    end
  end

  defp fallback_docs_url(%{"title" => "Proxmox Console"}) do
    "https://docs.serviceradar.cloud/docs/proxmox#console-access"
  end

  defp fallback_docs_url(_schema) do
    nil
  end

  defp text_input_type(%{"format" => "uri"}), do: "url"
  defp text_input_type(%{"format" => "email"}), do: "email"
  defp text_input_type(_), do: "text"

  defp value_for(params, name) do
    value = Map.get(params, name)

    cond do
      is_list(value) -> Enum.join(value, "\n")
      is_map(value) -> Jason.encode!(value)
      true -> value || ""
    end
  end

  defp truthy?(value) when is_boolean(value), do: value
  defp truthy?(value) when is_binary(value), do: String.downcase(value) == "true"
  defp truthy?(_), do: false

  defp secret_ref?(prop), do: Map.get(prop, "secretRef") == true

  defp current_secret_ref(params, name) do
    case Map.get(params, name) do
      value when is_binary(value) ->
        if String.starts_with?(value, "secretref:"), do: value

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
