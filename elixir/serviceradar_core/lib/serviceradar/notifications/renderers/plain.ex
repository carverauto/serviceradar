defmodule ServiceRadar.Notifications.Renderers.Plain do
  @moduledoc """
  `:plain` - unformatted text, for SMS gateways, plain-text email bodies, and any
  destination that renders nothing.

  Action links are written out in full rather than hidden behind link text,
  because there is no link text in plain text and a page that says "click here"
  with no URL is useless at 3am.
  """

  use ServiceRadar.Notifications.Renderers.Format

  @impl true
  def payload_format, do: :plain

  @impl true
  @spec render(Content.t()) :: map()
  def render(%Content{} = content) do
    compact(%{
      "subject" => presence(content.subject),
      "body" => content.body,
      "text" => text(content)
    })
  end

  defp text(content) do
    join_nonempty(
      [
        presence(content.subject),
        content.body,
        link_lines(content)
      ],
      "\n\n"
    )
  end

  defp link_lines(content) do
    content
    |> Content.action_links()
    |> Enum.map_join("\n", fn %{label: label, url: url} -> "#{label}: #{url}" end)
  end
end
