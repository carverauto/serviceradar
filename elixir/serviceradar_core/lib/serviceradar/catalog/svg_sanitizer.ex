defmodule ServiceRadar.Catalog.SvgSanitizer do
  @moduledoc """
  Server-side allowlist XML/SVG and Markdown sanitizer for Solution Packs (`2.3`).

  Protects `manifest.icon`, `assets/*.svg`, and `README.md` against stored XSS,
  XXE/external entity expansion, external beacon fetches, `<script>`,
  `<foreignObject>`, and `on*` event attributes before storage or rendering.
  """

  require Record

  Record.defrecordp(:xmlElement, Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl"))

  Record.defrecordp(
    :xmlAttribute,
    Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecordp(:xmlText, Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl"))

  @max_svg_bytes 262_144
  @max_markdown_bytes 524_288
  @svg_data_b64_prefix "data:image/svg+xml;base64,"
  @svg_data_utf8_prefix "data:image/svg+xml;utf8,"
  @svg_data_plain_prefix "data:image/svg+xml,"

  @allowed_tags MapSet.new(~w(
    svg
    defs
    linearGradient
    radialGradient
    stop
    rect
    circle
    ellipse
    line
    polyline
    polygon
    path
    g
    title
    desc
    clipPath
  ))

  @forbidden_tags MapSet.new(~w(
    script
    foreignobject
    iframe
    object
    embed
    image
    use
    audio
    video
    canvas
    animate
    animatemotion
    animatetransform
    set
    style
    link
    meta
  ))

  @allowed_attrs MapSet.new(~w(
    xmlns
    viewBox
    width
    height
    fill
    fill-opacity
    fill-rule
    stroke
    stroke-width
    stroke-linecap
    stroke-linejoin
    stroke-dasharray
    stroke-dashoffset
    stroke-opacity
    opacity
    transform
    clip-path
    clip-rule
    id
    d
    points
    x
    y
    x1
    y1
    x2
    y2
    cx
    cy
    r
    rx
    ry
    fx
    fy
    offset
    stop-color
    stop-opacity
    gradientUnits
    gradientTransform
    spreadMethod
    preserveAspectRatio
    role
    aria-label
    aria-hidden
    focusable
    href
    xlink:href
  ))

  @dangerous_css_or_url_regex ~r/(?i)(javascript\s*:|vbscript\s*:|data\s*:\s*text\/html|expression\s*\(|@import|url\s*\(\s*['"]?\s*(?:https?:|\/\/|javascript:|data:))/

  @doc """
  Validates and sanitizes an inline `<svg>...</svg>` string using a strict XML
  element and attribute allowlist.

  Strips disallowed tags (`<script>`, `<foreignObject>`, etc.), `on*` event
  attributes, `style` attributes, and external `href` / `xlink:href` URLs.
  """
  @spec sanitize_svg(term()) :: {:ok, String.t()} | {:error, atom() | {atom(), String.t()}}
  def sanitize_svg(svg) when is_binary(svg) do
    trimmed = String.trim(svg)

    cond do
      trimmed == "" ->
        {:error, :empty_svg}

      byte_size(trimmed) > @max_svg_bytes ->
        {:error, :svg_too_large}

      Regex.match?(~r/<!(?:DOCTYPE|ENTITY)/i, trimmed) ->
        {:error, :svg_dtd_forbidden}

      true ->
        parse_and_sanitize_xml(trimmed)
    end
  end

  def sanitize_svg(_other), do: {:error, :invalid_svg}

  @doc """
  Strictly validates an SVG or `data:image/svg+xml` icon, failing closed if any
  dangerous tag (`<script>`, `<foreignObject>`), `on*` event handler, or external
  `href` URL is present rather than silently stripping it.
  """
  @spec validate_svg(term()) :: {:ok, String.t()} | {:error, {atom(), String.t()}}
  def validate_svg(input) when is_binary(input) do
    with {:ok, raw_svg, wrapper} <- unwrap_svg_input(input),
         :ok <- reject_dangerous_constructs(raw_svg),
         {:ok, sanitized} <- sanitize_svg(raw_svg) do
      {:ok, rewrap_svg_output(sanitized, wrapper)}
    else
      {:error, {code, msg}} -> {:error, {code, msg}}
      {:error, code} when is_atom(code) -> {:error, {code, "invalid SVG content (#{code})"}}
    end
  end

  def validate_svg(_other), do: {:error, {:invalid_svg, "SVG icon must be a string"}}

  @doc """
  Sanitizes a `manifest.icon` value (accepting inline `<svg...>` or
  `data:image/svg+xml;base64,...`) and returns a canonical base64 SVG data URI.
  """
  @spec sanitize_icon(term()) :: {:ok, String.t()} | {:error, term()}
  def sanitize_icon(icon) when is_binary(icon) do
    with {:ok, raw_svg, _wrapper} <- unwrap_svg_input(icon),
         {:ok, clean_svg} <- sanitize_svg(raw_svg) do
      {:ok, @svg_data_b64_prefix <> Base.encode64(clean_svg)}
    end
  end

  def sanitize_icon(_other), do: {:error, :invalid_icon}

  @doc """
  Sanitizes pack `README.md` Markdown text before storage or preview rendering:
  strips raw `<script>`, `<iframe>`, `<object>`, `<embed>`, `<form>`, `<style>`,
  `<foreignObject>`, inline `on*` attributes, and `javascript:` / `vbscript:` /
  `data:text/html` links, and enforces `rel="noopener noreferrer"` on any raw
  HTML `<a ...>` anchor tags.
  """
  @spec sanitize_markdown(term()) :: {:ok, String.t()} | {:error, atom()}
  def sanitize_markdown(markdown) when is_binary(markdown) do
    if byte_size(markdown) > @max_markdown_bytes do
      {:error, :markdown_too_large}
    else
      cleaned =
        markdown
        |> strip_dangerous_html_blocks()
        |> strip_inline_event_handlers()
        |> neutralize_dangerous_markdown_links()
        |> enforce_anchor_noopener()

      {:ok, cleaned}
    end
  end

  def sanitize_markdown(_other), do: {:error, :invalid_markdown}

  defp unwrap_svg_input(input) do
    trimmed = String.trim(input)

    cond do
      String.starts_with?(trimmed, @svg_data_b64_prefix) ->
        b64 = String.replace_prefix(trimmed, @svg_data_b64_prefix, "")

        case Base.decode64(String.trim(b64)) do
          {:ok, decoded} -> {:ok, decoded, :data_b64}
          :error -> {:error, {:invalid_svg_base64, "icon base64 payload is malformed"}}
        end

      String.starts_with?(trimmed, @svg_data_utf8_prefix) ->
        body = trimmed |> String.replace_prefix(@svg_data_utf8_prefix, "") |> URI.decode()
        {:ok, body, :data_b64}

      String.starts_with?(trimmed, @svg_data_plain_prefix) ->
        body = trimmed |> String.replace_prefix(@svg_data_plain_prefix, "") |> URI.decode()
        {:ok, body, :data_b64}

      String.starts_with?(trimmed, "<") ->
        {:ok, trimmed, :inline}

      true ->
        {:error,
         {:invalid_svg_prefix, "icon must be inline <svg> or data:image/svg+xml;base64,..."}}
    end
  end

  defp rewrap_svg_output(clean_svg, :data_b64),
    do: @svg_data_b64_prefix <> Base.encode64(clean_svg)

  defp rewrap_svg_output(clean_svg, :inline), do: clean_svg

  defp parse_and_sanitize_xml(xml_str) do
    charlist = :unicode.characters_to_list(xml_str)

    opts = [
      quiet: true,
      comments: false,
      fetch_fun: fn _uri, state -> {:ok, {:string, ~c""}, state} end
    ]

    try do
      {root, trailing} = :xmerl_scan.string(charlist, opts)

      if String.trim(List.to_string(trailing)) == "" do
        case sanitize_root(root) do
          {:ok, serialized} -> {:ok, IO.iodata_to_binary(serialized)}
          {:error, _} = err -> err
        end
      else
        {:error, :invalid_svg}
      end
    catch
      :exit, _reason -> {:error, :invalid_svg}
      _, _reason -> {:error, :invalid_svg}
    end
  end

  defp sanitize_root(elem) when Record.is_record(elem, :xmlElement) do
    tag = elem |> xmlElement(:name) |> Atom.to_string()

    if tag == "svg" do
      sanitize_element(elem, true)
    else
      {:error, :invalid_svg_root}
    end
  end

  defp sanitize_root(_other), do: {:error, :invalid_svg_root}

  defp sanitize_element(elem, root?) do
    tag = elem |> xmlElement(:name) |> Atom.to_string()
    down_tag = String.downcase(tag)

    cond do
      MapSet.member?(@forbidden_tags, down_tag) ->
        {:ok, []}

      not MapSet.member?(@allowed_tags, tag) ->
        {:ok, []}

      true ->
        attrs = sanitize_attributes(xmlElement(elem, :attributes), root?)

        children =
          elem
          |> xmlElement(:content)
          |> Enum.reduce([], fn child, acc ->
            case sanitize_child(child, tag) do
              {:ok, iodata} -> [iodata | acc]
              :skip -> acc
            end
          end)
          |> Enum.reverse()

        attr_str =
          case attrs do
            [] ->
              ""

            list ->
              " " <> Enum.map_join(list, " ", fn {k, v} -> ~s(#{k}="#{escape_xml_attr(v)}") end)
          end

        if children == [] do
          {:ok, ["<", tag, attr_str, "/>"]}
        else
          {:ok, ["<", tag, attr_str, ">", children, "</", tag, ">"]}
        end
    end
  end

  defp sanitize_child(child, _parent_tag) when Record.is_record(child, :xmlElement) do
    case sanitize_element(child, false) do
      {:ok, []} -> :skip
      {:ok, iodata} -> {:ok, iodata}
    end
  end

  defp sanitize_child(text_node, parent_tag) when Record.is_record(text_node, :xmlText) do
    if parent_tag in ["title", "desc"] do
      val = text_node |> xmlText(:value) |> :unicode.characters_to_binary()
      {:ok, escape_xml_text(val)}
    else
      :skip
    end
  end

  defp sanitize_child(_other, _parent_tag), do: :skip

  defp sanitize_attributes(attrs, root?) do
    kept =
      attrs
      |> Enum.reduce([], fn attr, acc ->
        name = attr |> xmlAttribute(:name) |> Atom.to_string()
        value = attr |> xmlAttribute(:value) |> :unicode.characters_to_binary() |> String.trim()

        if allow_attribute?(name, value) do
          [{name, value} | acc]
        else
          acc
        end
      end)
      |> Enum.reverse()

    if root? and not List.keymember?(kept, "xmlns", 0) do
      [{"xmlns", "http://www.w3.org/2000/svg"} | kept]
    else
      kept
    end
  end

  defp allow_attribute?(name, value) do
    down_name = String.downcase(name)

    cond do
      String.starts_with?(down_name, "on") ->
        false

      not MapSet.member?(@allowed_attrs, name) ->
        false

      name == "xmlns" ->
        value == "http://www.w3.org/2000/svg"

      down_name in ["href", "xlink:href"] ->
        Regex.match?(~r/\A#[A-Za-z0-9._-]+\z/, value)

      Regex.match?(@dangerous_css_or_url_regex, value) ->
        false

      String.contains?(value, ["<", ">"]) ->
        false

      true ->
        true
    end
  end

  defp reject_dangerous_constructs(svg_str) do
    cond do
      Regex.match?(~r/<!(?:DOCTYPE|ENTITY)/i, svg_str) ->
        {:error, {:svg_dtd_forbidden, "SVG must not declare DOCTYPE or XML entities"}}

      Regex.match?(~r/<\s*(script|foreignObject|iframe|object|embed)\b/i, svg_str) ->
        {:error,
         {:svg_forbidden_element,
          "SVG contains forbidden active element (<script>/<foreignObject>)"}}

      Regex.match?(~r/\bon[a-z]+\s*=/i, svg_str) ->
        {:error,
         {:svg_event_handler_forbidden, "SVG contains forbidden inline event handler attribute"}}

      Regex.match?(~r/\b(?:xlink:)?href\s*=\s*["']\s*(?!#)[^"']+["']/i, svg_str) ->
        {:error,
         {:svg_external_href_forbidden,
          "SVG href/xlink:href must only reference local #fragment IDs"}}

      Regex.match?(@dangerous_css_or_url_regex, svg_str) ->
        {:error, {:svg_dangerous_uri, "SVG contains forbidden URI or CSS construct"}}

      true ->
        :ok
    end
  end

  defp strip_dangerous_html_blocks(md) do
    md
    |> String.replace(
      ~r/<\s*(script|iframe|object|embed|form|style|foreignObject)\b[^>]*>.*?<\s*\/\s*\1\s*>/is,
      ""
    )
    |> String.replace(
      ~r/<\s*\/?\s*(script|iframe|object|embed|form|style|foreignObject|meta|link|base)\b[^>]*>/i,
      ""
    )
  end

  defp strip_inline_event_handlers(md) do
    md
    |> String.replace(~r/\s+on[a-z0-9_-]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/i, "")
    |> String.replace(
      ~r/(?:href|src)\s*=\s*["']\s*(?:javascript|vbscript|data\s*:\s*text\/html)[^"']*["']/i,
      ~s(href="#")
    )
  end

  defp neutralize_dangerous_markdown_links(md) do
    Regex.replace(
      ~r/(\[[^\]]*\]\()\s*(?:javascript:|vbscript:|data:text\/html)[^)]*(\))/i,
      md,
      "\\1#\\2"
    )
  end

  defp enforce_anchor_noopener(md) do
    Regex.replace(~r/<a\b([^>]*)>/i, md, fn _full, attrs ->
      cleaned_attrs = String.replace(attrs, ~r/\s*rel\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/i, "")
      "<a#{cleaned_attrs} rel=\"noopener noreferrer\">"
    end)
  end

  defp escape_xml_attr(val) do
    val
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp escape_xml_text(val) do
    val
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
