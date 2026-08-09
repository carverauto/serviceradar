defmodule ServiceRadar.Notifications.Renderers.Content do
  @moduledoc """
  The already-substituted material a per-format renderer shapes into a payload.

  By the time a `Content` exists, every `{{ ... }}` has been resolved: `subject`
  and `body` are finished strings. A format module therefore never touches the
  template engine, never resolves a variable path, and never reads the clock -
  `timestamp` is supplied by the caller, like every other input, so rendering the
  same alert twice produces the same payload (design D9 and the decide-then-
  persist rule).

  `include_action_links?` exists for the `:stream` provider (design D7). A
  capability token is a single-use credential scoped to one delivery, and the
  firehose is a broadcast to every authorised subscriber; embedding one there
  hands an acknowledgement credential to every listener at once. A stream
  envelope therefore carries identifiers and no links, and it is the only
  exemption from the action-link requirement.
  """

  alias ServiceRadar.Notifications.Renderers.Format

  @enforce_keys [:payload_format, :body]

  defstruct [
    :payload_format,
    :subject,
    :body,
    :severity,
    :alert_class,
    :alert_id,
    :alert_url,
    :dedupe_key,
    :source,
    :timestamp,
    alert: %{},
    links: %{},
    include_action_links?: true,
    event_action: :trigger
  ]

  @type event_action :: :trigger | :resolve

  @type t :: %__MODULE__{
          payload_format: atom(),
          subject: String.t() | nil,
          body: String.t(),
          severity: String.t() | nil,
          alert_class: String.t() | nil,
          alert_id: String.t() | nil,
          alert_url: String.t() | nil,
          dedupe_key: String.t() | nil,
          source: String.t() | nil,
          timestamp: String.t() | nil,
          alert: map(),
          links: map(),
          include_action_links?: boolean(),
          event_action: event_action()
        }

  @type action_link :: %{action: atom(), label: String.t(), url: String.t()}

  # Fixed order and fixed wording. D7 names the three actions verbatim, and an
  # on-call engineer reading the same three buttons in the same order in Slack,
  # in email, and in a PagerDuty link list is the point.
  @actions [
    {:acknowledge, "Acknowledge"},
    {:snooze, "Snooze 1h"},
    {:resolve, "Resolve"}
  ]

  @doc """
  The acknowledge / snooze / resolve links, in fixed order.

  Returns `[]` when the destination is exempt from action links
  (`include_action_links?: false`, the `:stream` provider) and skips any action
  whose URL was not minted.
  """
  @spec action_links(t()) :: [action_link()]
  def action_links(%__MODULE__{include_action_links?: false}), do: []

  def action_links(%__MODULE__{links: links}) do
    Enum.flat_map(@actions, fn {action, label} ->
      case Format.presence(link(links, action)) do
        nil -> []
        url -> [%{action: action, label: label, url: url}]
      end
    end)
  end

  @doc """
  A named link from the link map, accepting either string or atom keys.

  `:alert` is the deep link to the alert in the ServiceRadar UI and is not an
  action link - it carries no capability token.
  """
  @spec link(map(), atom()) :: String.t() | nil
  def link(links, name) when is_map(links) and is_atom(name) do
    string = Atom.to_string(name)

    case Map.fetch(links, string) do
      {:ok, value} -> value
      :error -> Map.get(links, name)
    end
  end

  def link(_links, _name), do: nil

  @doc """
  A single-line fallback for destinations that want one: the subject when there
  is one, otherwise the first non-empty line of the body.
  """
  @spec summary(t()) :: String.t()
  def summary(%__MODULE__{subject: subject, body: body}) do
    case Format.presence(subject) do
      nil -> first_line(body)
      value -> value
    end
  end

  defp first_line(body) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find("", &(&1 != ""))
  end

  defp first_line(_body), do: ""
end
