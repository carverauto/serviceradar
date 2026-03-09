defmodule ServiceRadarWebNG.Edge.ComponentID do
  @moduledoc """
  Generates stable edge component identifiers from user-provided labels.
  """

  @spec generate(String.t() | nil, String.t() | atom()) :: String.t()
  def generate(label, component_type) do
    component_type = normalize_component_type(component_type)

    case slugify(label) do
      "" -> fallback_id(component_type)
      slug -> ensure_component_prefix(slug, component_type)
    end
  end

  defp normalize_component_type(component_type) when is_atom(component_type) do
    component_type
    |> Atom.to_string()
    |> normalize_component_type()
  end

  defp normalize_component_type(component_type) when is_binary(component_type) do
    component_type
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_component_type(_component_type), do: ""

  defp slugify(label) when is_binary(label) do
    label
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  defp slugify(_label), do: ""

  defp ensure_component_prefix(slug, ""), do: slug

  defp ensure_component_prefix(slug, component_type) do
    prefix = component_type <> "-"

    if String.starts_with?(slug, prefix) do
      slug
    else
      prefix <> slug
    end
  end

  defp fallback_id(""), do: Integer.to_string(:os.system_time(:millisecond))
  defp fallback_id(component_type), do: "#{component_type}-#{:os.system_time(:millisecond)}"
end
