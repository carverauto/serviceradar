defmodule ServiceRadarWebNGWeb.Settings.NotificationsLive.Presentation do
  @moduledoc """
  Label, badge, and filter vocabularies for the notification settings surface.

  Every enumerated value the UI accepts back from a browser - a delivery state, a
  suppression reason, an execution route, a boolean filter - is mapped through a
  literal list here. Nothing in this module calls `String.to_atom/1` or
  `String.to_existing_atom/1`, so a crafted query string cannot mint an atom, and
  an unrecognised value resolves to `nil` (drop the filter) rather than to a
  filter nobody wrote.

  State conveyed by colour is always paired with a text label, so the badge is
  legible to a screen reader and to anyone who cannot distinguish the hues. The
  `variant` values are `ServiceRadarWebNGWeb.UIComponents.ui_badge/1` variants,
  not daisyUI class names.
  """

  @delivery_states [
    {:pending, "Pending", "warning"},
    {:dispatching, "Dispatching", "info"},
    {:sent, "Sent", "success"},
    {:failed, "Failed", "error"},
    {:expired, "Expired", "ghost"},
    {:cancelled, "Cancelled", "ghost"},
    {:suppressed, "Suppressed", "warning"},
    {:skipped, "Skipped", "ghost"}
  ]

  @suppression_reasons [
    {:device_out_of_service, "Device out of service",
     "The subject device is marked inactive, so notifications for it are withheld."},
    {:silence, "Silence", "An active maintenance window matched this alert."},
    {:schedule, "Schedule", "The dispatch fell outside the route's schedule window."},
    {:snoozed, "Snoozed", "The alert was snoozed until a future time."},
    {:throttled, "Throttled", "The route's repeat cadence held this notification back."},
    {:acknowledged, "Acknowledged", "The alert was acknowledged, so escalation halted."},
    {:channel_disabled, "Channel disabled", "The channel or its provider is disabled, so the dispatch could not run."},
    {:dependency, "Dependency", "Reserved for topology-driven parent/child suppression; nothing emits it yet."},
    {:no_matching_route, "No matching route", "The alert matched zero enabled routes, so nothing was ever dispatched."}
  ]

  @payload_formats [:slack_blocks, :discord_embed, :markdown, :plain, :html, :pagerduty_v2, :json]

  @execution_routes [
    {:control_plane, "Control plane"},
    {:edge_agent, "Edge agent"}
  ]

  @channel_health [
    {:unknown, "Unknown", "ghost"},
    {:healthy, "Healthy", "success"},
    {:degraded, "Degraded", "warning"},
    {:failing, "Failing", "error"}
  ]

  @silence_states [
    {:scheduled, "Scheduled", "info"},
    {:active, "Active", "warning"},
    {:expired, "Expired", "ghost"},
    {:cancelled, "Cancelled", "ghost"}
  ]

  @provider_statuses [
    {:draft, "Draft", "ghost"},
    {:active, "Active", "success"},
    {:disabled, "Disabled", "error"}
  ]

  @provider_types [
    {:native, "Native", "Compiled in-tree; added by a release."},
    {:declarative, "Declarative", "An uploaded request-template document; no code, no release."},
    {:wasm_plugin, "Wasm plugin", "A signed OCI plugin bundle running on the agent host."},
    {:stream, "Stream", "Built in. Publishes the canonical envelope to the RBAC-scoped firehose; not an authorable tier."}
  ]

  @provider_sources [
    {:first_party, "First-party", "success"},
    {:uploaded, "Uploaded", "info"},
    {:plugin, "Plugin-backed", "warning"}
  ]

  # --- delivery state --------------------------------------------------------

  @doc "The delivery states, for a filter `<select>`."
  @spec delivery_states() :: [atom()]
  def delivery_states, do: Enum.map(@delivery_states, &elem(&1, 0))

  @spec delivery_state_options() :: [{String.t(), String.t()}]
  def delivery_state_options, do: Enum.map(@delivery_states, &{elem(&1, 1), to_string(elem(&1, 0))})

  @spec delivery_state_label(term()) :: String.t()
  def delivery_state_label(state), do: lookup_label(@delivery_states, state)

  @spec delivery_state_variant(term()) :: String.t()
  def delivery_state_variant(state), do: lookup_variant(@delivery_states, state)

  @doc "Maps a submitted state filter through the whitelist, or `nil`."
  @spec parse_delivery_state(term()) :: atom() | nil
  def parse_delivery_state(value), do: parse(@delivery_states, value)

  # --- suppression reason ----------------------------------------------------

  @spec suppression_reasons() :: [atom()]
  def suppression_reasons, do: Enum.map(@suppression_reasons, &elem(&1, 0))

  @spec suppression_reason_options() :: [{String.t(), String.t()}]
  def suppression_reason_options do
    Enum.map(@suppression_reasons, &{elem(&1, 1), to_string(elem(&1, 0))})
  end

  @spec suppression_reason_label(term()) :: String.t()
  def suppression_reason_label(reason), do: lookup_label(@suppression_reasons, reason)

  @doc "The sentence explaining why a dispatch carrying `reason` was withheld."
  @spec suppression_reason_explanation(term()) :: String.t()
  def suppression_reason_explanation(reason) do
    case find_entry(@suppression_reasons, reason) do
      {_reason, _label, explanation} -> explanation
      nil -> "The dispatch was withheld and the engine did not name a reason."
    end
  end

  @spec parse_suppression_reason(term()) :: atom() | nil
  def parse_suppression_reason(value), do: parse(@suppression_reasons, value)

  # --- payload format --------------------------------------------------------

  @spec payload_formats() :: [atom()]
  def payload_formats, do: @payload_formats

  @spec payload_format_options() :: [{String.t(), String.t()}]
  def payload_format_options, do: Enum.map(@payload_formats, &{humanize(&1), to_string(&1)})

  @spec parse_payload_format(term()) :: atom() | nil
  def parse_payload_format(value), do: parse_atoms(@payload_formats, value)

  # --- execution route -------------------------------------------------------

  @spec execution_routes() :: [atom()]
  def execution_routes, do: Enum.map(@execution_routes, &elem(&1, 0))

  @spec execution_route_label(term()) :: String.t()
  def execution_route_label(route), do: lookup_label(@execution_routes, route)

  @spec parse_execution_route(term()) :: atom() | nil
  def parse_execution_route(value), do: parse(@execution_routes, value)

  @doc """
  The `execution_route` options a provider actually supports.

  A route the provider does not declare is never offered, and the server
  re-checks the submitted value against the same list.
  """
  @spec route_options_for(term()) :: [{String.t(), String.t()}]
  def route_options_for(supported) when is_list(supported) do
    @execution_routes
    |> Enum.filter(fn {route, _label} -> route in supported end)
    |> Enum.map(fn {route, label} -> {label, to_string(route)} end)
  end

  def route_options_for(_supported), do: [{"Control plane", "control_plane"}]

  # --- channel health --------------------------------------------------------

  @spec channel_health_label(term()) :: String.t()
  def channel_health_label(health), do: lookup_label(@channel_health, health)

  @spec channel_health_variant(term()) :: String.t()
  def channel_health_variant(health), do: lookup_variant(@channel_health, health)

  # --- silence state ---------------------------------------------------------

  @spec silence_state_label(term()) :: String.t()
  def silence_state_label(state), do: lookup_label(@silence_states, state)

  @spec silence_state_variant(term()) :: String.t()
  def silence_state_variant(state), do: lookup_variant(@silence_states, state)

  # --- providers -------------------------------------------------------------

  @spec provider_status_label(term()) :: String.t()
  def provider_status_label(status), do: lookup_label(@provider_statuses, status)

  @spec provider_status_variant(term()) :: String.t()
  def provider_status_variant(status), do: lookup_variant(@provider_statuses, status)

  @spec provider_type_label(term()) :: String.t()
  def provider_type_label(type), do: lookup_label(@provider_types, type)

  @spec provider_type_explanation(term()) :: String.t()
  def provider_type_explanation(type) do
    case find_entry(@provider_types, type) do
      {_type, _label, explanation} -> explanation
      nil -> ""
    end
  end

  @doc """
  The tiers an operator can author against.

  `:stream` is a built-in provider type, not an extensibility tier: an operator
  cannot author one, so the upload flow must never offer it.
  """
  @spec authorable_tiers() :: [atom()]
  def authorable_tiers, do: [:declarative]

  @spec builtin_type?(term()) :: boolean()
  def builtin_type?(type), do: normalize(type) == "stream"

  @spec provider_source_label(term()) :: String.t()
  def provider_source_label(source), do: lookup_label(@provider_sources, source)

  @spec provider_source_variant(term()) :: String.t()
  def provider_source_variant(source), do: lookup_variant(@provider_sources, source)

  # --- generic helpers -------------------------------------------------------

  @doc """
  A redacted, bounded summary of a delivery's stored result.

  The Delivery Log never renders a wire payload: the engine persists only the
  redacted summary and the digest, and this reduces that to short scalar pairs so
  a nested provider response cannot smuggle a blob onto the page. The value is
  plain text and is escaped by the template - never `raw/1`.
  """
  @spec payload_summary(term(), non_neg_integer()) :: [{String.t(), String.t()}]
  def payload_summary(summary, limit \\ 8)

  def payload_summary(%{} = summary, limit) do
    summary
    |> Enum.reject(fn {_key, value} -> is_map(value) or is_list(value) end)
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.take(limit)
    |> Enum.map(fn {key, value} -> {to_string(key), truncate(to_string(value), 120)} end)
  end

  def payload_summary(_summary, _limit), do: []

  @doc """
  The id of the silence a suppressed delivery was withheld by, when the engine
  recorded one.

  Attribution rides in the suppression detail the evaluator already writes
  (`result_summary.suppression.detail.silence_id`), so the Delivery Log can point
  at the silence that caused a withheld page without a second attribution column
  that would have to be kept in step by hand.
  """
  @spec suppressing_silence_id(term()) :: String.t() | nil
  def suppressing_silence_id(%{} = result_summary) do
    result_summary
    |> get_path(["suppression", "detail", "silence_id"])
    |> case do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  def suppressing_silence_id(_result_summary), do: nil

  defp get_path(value, []), do: value
  defp get_path(%{} = map, [key | rest]), do: map |> Map.get(key) |> get_path(rest)
  defp get_path(_value, _path), do: nil

  @doc "Truncates a display string, marking that it was cut."
  @spec truncate(term(), pos_integer()) :: String.t()
  def truncate(value, max) when is_binary(value) do
    if String.length(value) > max, do: String.slice(value, 0, max) <> "...", else: value
  end

  def truncate(value, max), do: value |> to_string() |> truncate(max)

  @doc "Turns an enum atom into title case for a label with no explicit entry."
  @spec humanize(term()) :: String.t()
  def humanize(nil), do: "-"

  def humanize(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @doc "Parses a boolean filter value; anything else drops the filter."
  @spec parse_boolean(term()) :: boolean() | nil
  def parse_boolean(value) when value in ["true", true], do: true
  def parse_boolean(value) when value in ["false", false], do: false
  def parse_boolean(_value), do: nil

  defp lookup_label(entries, value) do
    case find_entry(entries, value) do
      nil -> humanize(value)
      entry -> elem(entry, 1)
    end
  end

  defp lookup_variant(entries, value) do
    case find_entry(entries, value) do
      nil -> "ghost"
      entry -> elem(entry, 2)
    end
  end

  # Comparison is by string on both sides, so a value that arrives as text
  # resolves without ever being cast into an atom.
  defp find_entry(_entries, nil), do: nil

  defp find_entry(entries, value) when is_atom(value) or is_binary(value) do
    target = to_string(value)
    Enum.find(entries, &(to_string(elem(&1, 0)) == target))
  end

  defp find_entry(_entries, _value), do: nil

  defp normalize(value) when is_atom(value) or is_binary(value), do: to_string(value)
  defp normalize(_value), do: nil

  defp parse(entries, value) when is_binary(value) do
    Enum.find_value(entries, fn entry ->
      known = elem(entry, 0)
      if to_string(known) == value, do: known
    end)
  end

  defp parse(_entries, value) when is_atom(value) and not is_nil(value), do: value
  defp parse(_entries, _value), do: nil

  defp parse_atoms(known, value) when is_binary(value) do
    Enum.find(known, &(to_string(&1) == value))
  end

  defp parse_atoms(known, value) when is_atom(value) and not is_nil(value) do
    if value in known, do: value
  end

  defp parse_atoms(_known, _value), do: nil
end
