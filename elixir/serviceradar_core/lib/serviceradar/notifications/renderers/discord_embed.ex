defmodule ServiceRadar.Notifications.Renderers.DiscordEmbed do
  @moduledoc """
  `:discord_embed` - a Discord webhook message carrying one embed.

  Action links go in an embed **field** as Markdown links rather than as message
  components. Components require a registered Discord application and an
  interaction endpoint; a webhook cannot send them. Phase 1's signed capability
  links work through a plain incoming webhook with no Discord app at all, which
  is the whole point of doing links before native interactivity (design D7).

  Discord's documented limits are enforced here (256 for a title, 4096 for a
  description, 1024 for a field value); exceeding one is a 400, which is a
  permanent failure rather than a retry.
  """

  use ServiceRadar.Notifications.Renderers.Format

  @title_limit 256
  @description_limit 4096
  @field_value_limit 1024

  # Fixed severity palette. Values are Discord's decimal colour integers.
  @colors %{
    "critical" => 14_038_051,
    "high" => 15_679_046,
    "error" => 15_679_046,
    "medium" => 16_760_576,
    "warning" => 16_760_576,
    "low" => 3_066_993,
    "info" => 3_447_003
  }
  @default_color 10_197_915

  @impl true
  def payload_format, do: :discord_embed

  @impl true
  @spec render(Content.t()) :: map()
  def render(%Content{} = content) do
    compact(%{"embeds" => [embed(content)]})
  end

  defp embed(content) do
    compact(%{
      "title" => truncate(presence(content.subject) || Content.summary(content), @title_limit),
      "description" => truncate(presence(content.body), @description_limit),
      "url" => presence(content.alert_url),
      "timestamp" => presence(content.timestamp),
      "color" => color(content.severity),
      "fields" => fields(content)
    })
  end

  defp color(severity) do
    case presence(severity) do
      nil -> @default_color
      value -> Map.get(@colors, String.downcase(value), @default_color)
    end
  end

  defp fields(content) do
    Enum.reject(
      [
        field("Severity", content.severity, true),
        field("Class", content.alert_class, true),
        field("Source", content.source, true),
        open_field(content),
        field("Actions", action_field(content), false)
      ],
      &is_nil/1
    )
  end

  defp open_field(content) do
    case presence(content.alert_url) do
      nil -> nil
      url -> field("Open in ServiceRadar", "[Open alert](#{url})", false)
    end
  end

  defp field(name, value, inline?) do
    case presence(value) do
      nil ->
        nil

      present ->
        %{"name" => name, "value" => truncate(present, @field_value_limit), "inline" => inline?}
    end
  end

  defp action_field(content) do
    content
    |> Content.action_links()
    |> Enum.map_join(" | ", fn %{label: label, url: url} -> "[#{label}](#{url})" end)
  end
end
