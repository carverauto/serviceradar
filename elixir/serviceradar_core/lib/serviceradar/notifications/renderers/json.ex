defmodule ServiceRadar.Notifications.Renderers.Json do
  @moduledoc """
  `:json` - a structured body for generic webhooks and `:declarative` providers.

  Two shapes are possible, and which one you get is decided by the template, not
  by configuration:

    * If the rendered body parses as a JSON **object**, that object IS the
      payload. This is how an operator addresses a destination with a fixed
      schema: they write the document and use the `json` filter for every
      substituted value.
    * Otherwise the body is carried inside a stable ServiceRadar envelope. That
      covers the common case of a Markdown-ish body pointed at a webhook, and it
      is also the honest degradation when a substituted value broke the operator's
      JSON (an unescaped quote in an alert title) - the notification still leaves,
      in a shape a receiver can parse.

  Substituted values are not auto-escaped here, because the `json` filter is the
  documented way to escape them (design D9) and escaping twice would emit
  `"\\"value\\""` into every field.
  """

  use ServiceRadar.Notifications.Renderers.Format

  @impl true
  def payload_format, do: :json

  @impl true
  @spec render(Content.t()) :: map()
  def render(%Content{} = content) do
    case Jason.decode(content.body) do
      {:ok, %{} = document} -> document
      _other -> envelope(content)
    end
  end

  defp envelope(content) do
    compact(%{
      "subject" => presence(content.subject),
      "body" => content.body,
      "alert_id" => presence(content.alert_id),
      "alert_class" => presence(content.alert_class),
      "severity" => presence(content.severity),
      "source" => presence(content.source),
      "dedupe_key" => presence(content.dedupe_key),
      "timestamp" => presence(content.timestamp),
      "alert_url" => presence(content.alert_url),
      "links" => links(content)
    })
  end

  defp links(content) do
    content
    |> Content.action_links()
    |> Enum.map(fn %{action: action, label: label, url: url} ->
      %{"action" => Atom.to_string(action), "label" => label, "url" => url}
    end)
  end
end
