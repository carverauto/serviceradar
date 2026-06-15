defmodule ServiceRadar.Inventory.AdvisoryFeeds.Cpe do
  @moduledoc """
  CPE 2.3 URI parsing and component normalization.

  CPE 2.3 formatted-string binding:

      cpe:2.3:part:vendor:product:version:update:edition:language:sw_edition:target_sw:target_hw:other

  We only normalize the components used for endpoint matching (`part`, `vendor`,
  `product`, `version`). Components are lower-cased; CPE escape sequences (`\\:`,
  `\\.`, etc.) are unescaped. The special values `*` (ANY) and `-` (NA) are
  preserved verbatim so the matcher can apply wildcard semantics.

  Pure module — no DB, no IO. Fully unit-testable.
  """

  @type components :: %{
          part: String.t() | nil,
          vendor: String.t() | nil,
          product: String.t() | nil,
          version: String.t() | nil
        }

  @doc """
  Parse a CPE 2.3 formatted string into normalized components.

  Returns `{:ok, components}` or `:error` for non-CPE-2.3 strings. CPE 2.2 URIs
  (`cpe:/a:...`) are intentionally not supported (NVD 2.0 / VulnCheck emit 2.3).
  """
  @spec parse(String.t()) :: {:ok, components()} | :error
  def parse(value) when is_binary(value) do
    case split_cpe(value) do
      {:ok, parts} ->
        {:ok,
         %{
           part: component(parts, 0),
           vendor: component(parts, 1),
           product: component(parts, 2),
           version: component(parts, 3)
         }}

      :error ->
        :error
    end
  end

  def parse(_), do: :error

  @doc """
  Parse a CPE, returning `nil` components on failure (convenience for bulk load).
  """
  @spec parse_components(String.t()) :: components()
  def parse_components(value) do
    case parse(value) do
      {:ok, components} -> components
      :error -> %{part: nil, vendor: nil, product: nil, version: nil}
    end
  end

  @doc """
  Does a single advisory CPE component match an installed package component?

  ANY (`*`) and NA (`-`) on the advisory side match anything. A `nil` advisory
  component is treated as ANY. Otherwise case-insensitive equality.
  """
  @spec component_match?(String.t() | nil, String.t() | nil) :: boolean()
  def component_match?(advisory_component, installed_component)

  def component_match?(nil, _installed), do: true
  def component_match?("*", _installed), do: true
  def component_match?("-", _installed), do: true

  def component_match?(advisory, installed) when is_binary(advisory) and is_binary(installed) do
    String.downcase(advisory) == String.downcase(installed)
  end

  def component_match?(_advisory, _installed), do: false

  # cpe:2.3:a:vendor:product:version:...  -> the 11 components after "cpe:2.3:"
  defp split_cpe("cpe:2.3:" <> rest) do
    {:ok, split_escaped(rest)}
  end

  defp split_cpe(_), do: :error

  # Split on unescaped colons, then unescape each component.
  defp split_escaped(string) do
    string
    |> do_split([], [])
    |> Enum.map(&unescape/1)
  end

  defp do_split(<<>>, current, acc) do
    Enum.reverse([finish(current) | acc])
  end

  defp do_split(<<"\\", c, rest::binary>>, current, acc) do
    do_split(rest, [c, "\\" | current], acc)
  end

  defp do_split(<<":", rest::binary>>, current, acc) do
    do_split(rest, [], [finish(current) | acc])
  end

  defp do_split(<<c, rest::binary>>, current, acc) do
    do_split(rest, [c | current], acc)
  end

  defp finish(current) do
    current
    |> Enum.reverse()
    |> Enum.map_join(fn
      c when is_integer(c) -> <<c>>
      c -> c
    end)
  end

  defp component(parts, index) do
    case Enum.at(parts, index) do
      nil -> nil
      "" -> nil
      value -> String.downcase(value)
    end
  end

  # Unescape CPE backslash escapes (\\: \\. \\* etc.) but preserve bare * and -.
  defp unescape(component) do
    String.replace(component, ~r/\\(.)/, "\\1")
  end
end
