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

  defp actions_block(%Content{interactive?: true} = content) do
    case Content.action_controls(content) do
      [] -> nil
      controls -> %{"type" => "actions", "elements" => Enum.map(controls, &control_button/1)}
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

  # An interactive button carries NO `url`. Slack treats a button with a `url` as
  # a link that also opens a browser tab, which is not what an acknowledge
  # control should do - and in interactive mode the click already reaches us as a
  # signed interaction, so a URL would be a second, weaker ingress carrying a
  # capability token we deliberately did not mint.
  #
  # `value` carries the binding the callback needs to reconstruct the capability.
  # It is a compact, delimited string rather than JSON because Slack caps `value`
  # at 2000 bytes and a JSON envelope spends a third of that on punctuation.
  defp control_button(%{action: action} = control) do
    compact(%{
      "type" => "button",
      "text" => %{
        "type" => "plain_text",
        "text" => truncate(control.label, @button_limit),
        "emoji" => false
      },
      "action_id" => "notification_" <> Atom.to_string(action),
      "value" => control_value(control),
      "style" => Map.get(@button_styles, action)
    })
  end

  @doc """
  The `value` an interactive button carries, and the format the callback parses.

  `"<action>:<alert_id>:<delivery_id>"`, with a snooze duration appended as a
  fourth field. Public so the callback parses the format this module writes
  rather than a restatement of it.
  """
  @spec control_value(map()) :: String.t()
  def control_value(%{action: action, alert_id: alert_id, delivery_id: delivery_id} = control) do
    [Atom.to_string(action), alert_id, delivery_id]
    |> then(fn parts ->
      case Map.get(control, :snooze_seconds) do
        seconds when is_integer(seconds) and seconds > 0 -> parts ++ [Integer.to_string(seconds)]
        _absent -> parts
      end
    end)
    |> Enum.join(":")
    |> truncate(2000)
  end
end
