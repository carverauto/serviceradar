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
    # Carried for interactive controls (D7 phase 2), which bind to a delivery
    # rather than to a URL. A Phase 1 link binds both alert and delivery - and
    # `ActionLinks` refuses to mint without both - so a control that could only
    # bind `alert_id` would be a WEAKER binding than the link it replaces.
    :delivery_id,
    # The duration a Snooze control grants. Carried rather than defaulted at the
    # point of use because `ActionRedemption.apply_native/2` refuses a snooze
    # with no duration, exactly as `ActionToken` does; a default invented in a
    # renderer would mean the two ingresses to one mechanism disagreeing about
    # how long "Snooze 1h" is.
    :snooze_seconds,
    alert: %{},
    links: %{},
    include_action_links?: true,
    # Interactive mode (D7 phase 2). When true a provider that supports it
    # renders `action_controls/1` as controls that POST an interaction, instead
    # of `action_links/1` as URL buttons. Default false: a channel whose app has
    # no Interactivity Request URL configured would render buttons that produce
    # no request and no log, so this is opt-in per channel.
    interactive?: false,
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
          delivery_id: String.t() | nil,
          snooze_seconds: pos_integer() | nil,
          alert: map(),
          links: map(),
          include_action_links?: boolean(),
          interactive?: boolean(),
          event_action: event_action()
        }

  @type action_link :: %{action: atom(), label: String.t(), url: String.t()}

  @type action_control :: %{
          action: atom(),
          label: String.t(),
          alert_id: String.t(),
          delivery_id: String.t(),
          snooze_seconds: pos_integer() | nil
        }

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
  The acknowledge / snooze / resolve **interactive controls**, in fixed order.

  The interactive-mode counterpart of `action_links/1`, for providers whose
  buttons post an interaction rather than opening a URL (D7 phase 2). A control
  carries the identifiers the callback needs to reconstruct the capability, and
  no URL and no token.

  Returns `[]` in three cases, and the first is the one that matters:

    * `include_action_links?: false` - the `:stream` exemption. This clause is
      first and matches the struct exactly as `action_links/1` does, so a new
      interactive call site cannot route around the exemption by reaching for a
      different accessor. A firehose must no more carry an actionable control
      than an actionable link.
    * no `delivery_id` - a control bound to an alert alone is a weaker binding
      than the Phase 1 link it replaces, and `ActionLinks` refuses to mint one.
    * no `alert_id` - there is nothing to act on.

  The snooze control is omitted when `snooze_seconds` is absent rather than
  rendered with a house default, because `ActionRedemption.apply_native/2`
  refuses a snooze with no duration. Rendering a button that is guaranteed to
  fail on click is worse than not rendering it.
  """
  @spec action_controls(t()) :: [action_control()]
  def action_controls(%__MODULE__{include_action_links?: false}), do: []

  def action_controls(%__MODULE__{alert_id: alert_id, delivery_id: delivery_id})
      when not is_binary(alert_id) or not is_binary(delivery_id), do: []

  def action_controls(%__MODULE__{} = content) do
    Enum.flat_map(@actions, fn {action, label} ->
      case control(action, label, content) do
        nil -> []
        control -> [control]
      end
    end)
  end

  defp control(:snooze, _label, %__MODULE__{snooze_seconds: seconds})
       when not (is_integer(seconds) and seconds > 0),
       do: nil

  defp control(action, label, content) do
    %{
      action: action,
      label: label,
      alert_id: content.alert_id,
      delivery_id: content.delivery_id,
      snooze_seconds: if(action == :snooze, do: content.snooze_seconds)
    }
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
