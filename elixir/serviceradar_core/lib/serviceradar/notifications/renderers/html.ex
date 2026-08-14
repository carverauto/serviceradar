defmodule ServiceRadar.Notifications.Renderers.Html do
  @moduledoc """
  `:html` - HTML email bodies.

  This is the one format that overrides `escape/1`. The literal template is
  operator-authored markup and is emitted as written; every **substituted value**
  is HTML-escaped on the way in, so an alert whose title is
  `<img src=x onerror=...>` renders as text in an inbox instead of executing
  there.

  Note that `:html` as a `payload_format` is a destination format and is a
  different thing from the `html` *key* design D9 rejects in provider-supplied UI
  descriptors. Nothing here calls `raw/1`; there is no "mark this safe" step to
  get wrong, because the two inputs are kept apart by construction.
  """

  use ServiceRadar.Notifications.Renderers.Format

  @impl true
  def payload_format, do: :html

  @impl true
  @spec escape(String.t()) :: String.t()
  def escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  @impl true
  @spec render(Content.t()) :: map()
  def render(%Content{} = content) do
    compact(%{
      "subject" => presence(content.subject),
      "body" => content.body,
      "html" => document(content)
    })
  end

  defp document(content) do
    join_nonempty(
      [
        heading(content.subject),
        "<div class=\"serviceradar-notification-body\">" <> content.body <> "</div>",
        link_paragraph(content)
      ],
      "\n"
    )
  end

  # The subject is a plain-text field everywhere else (an email Subject: header,
  # a Slack header block), so it is escaped rather than trusted as markup here.
  defp heading(subject) do
    case presence(subject) do
      nil -> nil
      value -> "<h2>" <> escape(value) <> "</h2>"
    end
  end

  defp link_paragraph(content) do
    case Content.action_links(content) do
      [] ->
        nil

      links ->
        anchors =
          Enum.map_join(links, " ", fn %{label: label, url: url} ->
            "<a href=\"" <> escape(url) <> "\">" <> escape(label) <> "</a>"
          end)

        "<p class=\"serviceradar-notification-actions\">" <> anchors <> "</p>"
    end
  end
end
