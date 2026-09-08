defmodule ServiceRadar.Notifications.Renderers.Markdown do
  @moduledoc """
  `:markdown` - the generic rich-text format, used by destinations that accept
  Markdown in a single text field (generic webhooks, Mattermost, Rocket.Chat,
  Telegram, ntfy).

  Substituted values are NOT Markdown-escaped. Escaping them would corrupt every
  alert title containing an underscore or an asterisk, which is most device
  names, and Markdown has no injection surface worth the trade: the worst a
  crafted title achieves is bold text.
  """

  use ServiceRadar.Notifications.Renderers.Format

  @impl true
  def payload_format, do: :markdown

  @impl true
  @spec render(Content.t()) :: map()
  def render(%Content{} = content) do
    compact(%{
      "subject" => presence(content.subject),
      "body" => content.body,
      "text" => text(content),
      "severity" => presence(content.severity),
      "alert_class" => presence(content.alert_class)
    })
  end

  defp text(content) do
    join_nonempty(
      [
        heading(content.subject),
        content.body,
        link_row(content)
      ],
      "\n\n"
    )
  end

  defp heading(subject) do
    case presence(subject) do
      nil -> nil
      value -> "### " <> value
    end
  end

  defp link_row(content) do
    content
    |> Content.action_links()
    |> Enum.map_join(" | ", fn %{label: label, url: url} -> "[#{label}](#{url})" end)
  end
end
