defmodule ServiceRadarWebNGWeb.PluginConfigForm do
  @moduledoc false

  use Phoenix.Component

  attr :schema, :map, default: %{}
  attr :params, :map, default: %{}
  attr :base_name, :string, default: "params"

  def plugin_config_fields(assigns) do
    schema = normalize_schema(assigns.schema)
    params = normalize_params(assigns.params)
    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", [])

    assigns =
      assigns
      |> assign(:schema, schema)
      |> assign(:params, params)
      |> assign(:properties, properties)
      |> assign(:required, required)

    ~H"""
    <div class="space-y-4">
      <%= for {name, prop} <- @properties do %>
        <div class="space-y-2">
          <label class="label">
            <span class="label-text">
              {Map.get(prop, "title") || name}
              <%= if name in @required do %>
                <span class="text-error">*</span>
              <% end %>
            </span>
          </label>

          <%= case input_type(prop) do %>
            <% :select -> %>
              <select
                name={input_name(@base_name, name)}
                class="select select-bordered w-full"
              >
                <%= for option <- Map.get(prop, "enum", []) do %>
                  <option
                    value={option}
                    selected={option == value_for(@params, name)}
                  >
                    {option}
                  </option>
                <% end %>
              </select>
            <% :checkbox -> %>
              <div class="flex items-center gap-2">
                <input type="hidden" name={input_name(@base_name, name)} value="false" />
                <input
                  type="checkbox"
                  name={input_name(@base_name, name)}
                  value="true"
                  class="checkbox checkbox-sm"
                  checked={truthy?(value_for(@params, name))}
                />
                <span class="text-xs text-base-content/60">Enable</span>
              </div>
            <% :textarea -> %>
              <textarea
                name={input_name(@base_name, name)}
                class="textarea textarea-bordered w-full font-mono text-xs min-h-[100px]"
                placeholder={array_placeholder(prop)}
              ><%= value_for(@params, name) %></textarea>
            <% :number -> %>
              <input
                type="number"
                name={input_name(@base_name, name)}
                value={value_for(@params, name)}
                min={Map.get(prop, "minimum")}
                max={Map.get(prop, "maximum")}
                class="input input-bordered w-full"
              />
            <% :text -> %>
              <input
                type={text_input_type(prop)}
                name={input_name(@base_name, name)}
                value={value_for(@params, name)}
                minlength={Map.get(prop, "minLength")}
                maxlength={Map.get(prop, "maxLength")}
                pattern={Map.get(prop, "pattern")}
                class="input input-bordered w-full"
              />
          <% end %>

          <%= if is_binary(Map.get(prop, "description")) and Map.get(prop, "description") != "" do %>
            <p class="text-xs text-base-content/60">{Map.get(prop, "description")}</p>
          <% end %>
        </div>
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
    map
    |> Enum.map(fn {key, value} -> {to_string(key), stringify_keys(value)} end)
    |> Map.new()
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp input_name(base, name), do: "#{base}[#{name}]"

  defp input_type(%{"enum" => enum}) when is_list(enum) and enum != [], do: :select
  defp input_type(%{"type" => "boolean"}), do: :checkbox
  defp input_type(%{"type" => "integer"}), do: :number
  defp input_type(%{"type" => "number"}), do: :number
  defp input_type(%{"type" => "array"}), do: :textarea
  defp input_type(_), do: :text

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

  defp array_placeholder(prop) do
    case get_in(prop, ["items", "type"]) do
      "string" -> "one per line"
      "integer" -> "e.g. 1\n2\n3"
      "number" -> "e.g. 1.5\n2.5"
      _ -> "one per line"
    end
  end
end
