defmodule ServiceRadar.Notifications.Renderers.SlackBlocks do
  @moduledoc """
  `:slack_blocks` - Slack Block Kit.

  `text` is populated even though `blocks` is present: Slack uses it for the
  notification preview and for clients that cannot render blocks, and a message
  with blocks but no `text` shows as "This content can't be displayed" in
  exactly the surfaces an on-call engineer looks at first.

  Slack's hard field limits are enforced here (150 characters for a `header`,
  3000 for a `section`). Exceeding them is an HTTP 400, which is a permanent
  failure - so the page would be lost, not delayed, for the sake of a long device
  name.

  The action buttons are Phase 1 signed capability links (design D7 phase 1):
  plain `url` buttons that need no Slack app, no interactivity endpoint, and no
  per-provider code. Phase 4 replaces them with interactive components verified
  through the northbound HMAC scheme; the block shape does not have to change for
  that.
  """

  use ServiceRadar.Notifications.Renderers.Format

  @header_limit 150
  @section_limit 3000
  @context_limit 2000
  @button_limit 75

  @button_styles %{acknowledge: "primary", resolve: "danger"}

  @impl true
  def payload_format, do: :slack_blocks

  @impl true
  @spec render(Content.t()) :: map()
  def render(%Content{} = content) do
    compact(%{
      "text" => truncate(Content.summary(content), @section_limit),
      "blocks" => blocks(content)
    })
  end

  defp blocks(content) do
    Enum.reject(
      [
        header_block(content.subject),
        section_block(content.body),
        context_block(content),
        actions_block(content)
      ],
      &is_nil/1
    )
  end

  defp header_block(subject) do
    case presence(subject) do
      nil ->
        nil

      value ->
        %{
          "type" => "header",
          "text" => %{
            "type" => "plain_text",
            "text" => truncate(value, @header_limit),
            "emoji" => true
          }
        }
    end
  end

  defp section_block(body) do
    case presence(body) do
      nil ->
        nil

      value ->
        %{
          "type" => "section",
          "text" => %{"type" => "mrkdwn", "text" => truncate(value, @section_limit)}
        }
    end
  end

  defp context_block(content) do
    text =
      join_nonempty(
        [
          label("Severity", content.severity),
          label("Class", content.alert_class),
          label("Source", content.source),
          label("Dedupe", content.dedupe_key)
        ],
        "  |  "
      )

    case presence(text) do
      nil ->
        nil

      value ->
        %{
          "type" => "context",
          "elements" => [%{"type" => "mrkdwn", "text" => truncate(value, @context_limit)}]
        }
    end
  end

  defp label(name, value) do
    case presence(value) do
      nil -> nil
      present -> "*#{name}:* #{present}"
    end
  end

  defp actions_block(content) do
    case Content.action_links(content) do
      [] -> nil
      links -> %{"type" => "actions", "elements" => Enum.map(links, &button(&1, content))}
    end
  end

  defp button(%{action: action, label: label, url: url}, content) do
    compact(%{
      "type" => "button",
      "text" => %{
        "type" => "plain_text",
        "text" => truncate(label, @button_limit),
        "emoji" => false
      },
      "url" => url,
      "action_id" => "notification_" <> Atom.to_string(action),
      "value" => truncate(presence(content.dedupe_key) || presence(content.alert_id), 2000),
      "style" => Map.get(@button_styles, action)
    })
  end
end
