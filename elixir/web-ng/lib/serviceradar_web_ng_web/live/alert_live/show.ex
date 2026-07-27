defmodule ServiceRadarWebNGWeb.AlertLive.Show do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadar.Observability.EventTitle

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Alert Details")
     |> assign(:alert_id, nil)
     |> assign(:alert, nil)
     |> assign(:error, nil)
     |> assign(:srql, %{enabled: false})}
  end

  @impl true
  def handle_params(%{"alert_id" => alert_id}, _uri, socket) do
    query = "in:alerts id:\"#{escape_value(alert_id)}\" limit:1"

    {alert, error} =
      case srql_module().query(query) do
        {:ok, %{"results" => [alert | _]}} when is_map(alert) ->
          {alert, nil}

        {:ok, %{"results" => []}} ->
          {nil, "Alert not found."}

        {:ok, _other} ->
          {nil, "Unexpected response format"}

        {:error, reason} ->
          {nil, "Failed to load alert: #{format_error(reason)}"}
      end

    {:noreply,
     socket
     |> assign(:alert_id, alert_id)
     |> assign(:alert, alert)
     |> assign(:error, error)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-4xl p-6">
        <.header>
          Alert Details
          <:subtitle>
            <span class="font-mono text-xs">{@alert_id}</span>
          </:subtitle>
          <:actions>
            <.ui_button href={~p"/alerts"} variant="ghost" size="sm">
              Back to alerts
            </.ui_button>
          </:actions>
        </.header>

        <div :if={@error} class="rounded-xl border border-error/30 bg-error/5 p-6 text-center">
          <p class="text-sm text-error">{@error}</p>
        </div>

        <div :if={is_map(@alert)} class="space-y-4">
          <.alert_summary alert={@alert} />
          <.stateful_incident_summary :if={stateful_incident?(@alert)} alert={@alert} />
          <.alert_links alert={@alert} />
          <.alert_details alert={@alert} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :alert, :map, required: true

  defp alert_summary(assigns) do
    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface p-6">
      <div class="flex flex-wrap gap-x-8 gap-y-4 items-start">
        <div class="flex flex-col gap-1">
          <span class="text-xs text-sr-muted uppercase tracking-wider">Severity</span>
          <.severity_badge value={Map.get(@alert, "severity")} />
        </div>

        <div class="flex flex-col gap-1">
          <span class="text-xs text-sr-muted uppercase tracking-wider">Status</span>
          <.status_badge value={Map.get(@alert, "status")} />
        </div>

        <div class="flex flex-col gap-1">
          <span class="text-xs text-sr-muted uppercase tracking-wider">Triggered</span>
          <span class="text-sm font-mono">{format_timestamp(@alert)}</span>
        </div>
      </div>

      <div class="mt-6 pt-6 border-t border-sr-line space-y-3">
        <div>
          <span class="text-xs text-sr-muted uppercase tracking-wider block mb-1">Title</span>
          <p class="text-sm font-semibold">{EventTitle.alert_title(@alert)}</p>
        </div>
        <div :if={has_value?(@alert, "description")}>
          <span class="text-xs text-sr-muted uppercase tracking-wider block mb-1">
            Description
          </span>
          <p class="text-sm whitespace-pre-wrap">{Map.get(@alert, "description")}</p>
        </div>
      </div>
    </div>
    """
  end

  attr :alert, :map, required: true

  defp stateful_incident_summary(assigns) do
    diagnostics = incident_diagnostics(assigns.alert)

    assigns =
      assigns
      |> assign(:diagnostics, diagnostics)
      |> assign(:samples, diagnostic_value(diagnostics, ["samples"]) || %{})
      |> assign(:process, first_sample(diagnostics, "processes"))
      |> assign(:container, first_sample(diagnostics, "containers"))
      |> assign(:kubernetes, first_sample(diagnostics, "kubernetes"))

    ~H"""
    <div class="rounded-xl border border-error/20 bg-error/5 p-6">
      <div class="flex items-start justify-between gap-4">
        <div class="min-w-0">
          <span class="text-xs text-error uppercase tracking-wider block mb-2">
            Stateful Incident
          </span>
          <h2 class="text-lg font-semibold leading-tight">
            {diagnostic_value(@diagnostics, ["rule_name"]) || Map.get(@alert, "title") ||
              "Rule threshold fired"}
          </h2>
        </div>
        <.severity_badge value={Map.get(@alert, "severity")} />
      </div>

      <div class="mt-5 grid grid-cols-1 sm:grid-cols-2 gap-4">
        <.diagnostic_fact label="Group" value={diagnostic_value(@diagnostics, ["group_key"])} mono />
        <.diagnostic_fact
          label="Window Count"
          value={diagnostic_value(@diagnostics, ["window_count"])}
          mono
        />
        <.diagnostic_fact
          label="Threshold"
          value={diagnostic_value(@diagnostics, ["threshold"])}
          mono
        />
        <.diagnostic_fact label="Window" value={window_display(@diagnostics)} mono />
        <.diagnostic_fact
          label="First Seen"
          value={diagnostic_value(@diagnostics, ["first_seen_at"])}
          mono
        />
        <.diagnostic_fact
          label="Last Seen"
          value={diagnostic_value(@diagnostics, ["last_seen_at"])}
          mono
        />
        <.diagnostic_fact
          label="Representative Events"
          value={diagnostic_value(@diagnostics, ["representative_event_ids"])}
          mono
        />
        <.diagnostic_fact label="Process" value={process_display(@process)} mono />
        <.diagnostic_fact label="Container" value={container_display(@container)} mono />
        <.diagnostic_fact label="Image" value={image_display(@container)} mono />
        <.diagnostic_fact label="Kubernetes Pod" value={kubernetes_display(@kubernetes)} mono />
        <.diagnostic_fact label="Attribution" value={attribution_display(@kubernetes)} />
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :mono, :boolean, default: false

  defp diagnostic_fact(assigns) do
    ~H"""
    <div class="min-w-0">
      <span class="text-xs text-sr-muted uppercase tracking-wider block mb-1">
        {@label}
      </span>
      <span class={[
        "text-sm break-words",
        if(@mono, do: "font-mono", else: nil),
        if(blank?(@value), do: "text-sr-muted", else: nil)
      ]}>
        {display_diagnostic_value(@value)}
      </span>
    </div>
    """
  end

  attr :alert, :map, required: true

  defp alert_links(assigns) do
    event_id = Map.get(assigns.alert, "event_id")

    assigns = assign(assigns, :event_id, event_id)

    ~H"""
    <div
      :if={is_binary(@event_id)}
      class="rounded-xl border border-sr-line bg-sr-surface p-6"
    >
      <span class="text-xs text-sr-muted uppercase tracking-wider block mb-3">
        Related Records
      </span>
      <div class="flex flex-wrap gap-2">
        <.ui_button :if={@event_id} href={~p"/events/#{@event_id}"} size="sm" variant="ghost">
          View triggering event
        </.ui_button>
      </div>
    </div>
    """
  end

  attr :alert, :map, required: true

  defp alert_details(assigns) do
    detail_fields =
      ~w(source_type source_id service_check_id device_uid agent_uid metric_name metric_value threshold_value comparison event_id event_time)

    metadata = Map.get(assigns.alert, "metadata") || %{}

    assigns =
      assigns
      |> assign(:detail_fields, detail_fields)
      |> assign(:metadata, metadata)

    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface p-6 space-y-6">
      <div>
        <span class="text-xs text-sr-muted uppercase tracking-wider block mb-3">
          Alert Fields
        </span>
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-3">
          <%= for field <- @detail_fields do %>
            <div class="flex flex-col gap-0.5 min-w-0">
              <span class="text-xs text-sr-muted">{field_label(field)}</span>
              <.inline_value value={Map.get(@alert, field)} />
            </div>
          <% end %>
        </div>
      </div>

      <div :if={is_map(@metadata) and map_size(@metadata) > 0}>
        <span class="text-xs text-sr-muted uppercase tracking-wider block mb-3">
          Metadata
        </span>
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-3">
          <%= for {field, value} <- Enum.sort(@metadata) do %>
            <div class="flex flex-col gap-0.5 min-w-0">
              <span class="text-xs text-sr-muted">{field_label(field)}</span>
              <.inline_value value={value} />
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :value, :any, default: nil

  defp inline_value(%{value: nil} = assigns) do
    ~H|<span class="text-sr-muted text-sm">—</span>|
  end

  defp inline_value(%{value: ""} = assigns) do
    ~H|<span class="text-sr-muted text-sm">—</span>|
  end

  defp inline_value(%{value: value} = assigns) when is_boolean(value) do
    assigns = assign(assigns, :value_text, to_string(value))

    ~H|<span class="text-sm font-mono">{@value_text}</span>|
  end

  defp inline_value(%{value: value} = assigns) when is_number(value) do
    assigns = assign(assigns, :value_text, to_string(value))

    ~H|<span class="text-sm font-mono">{@value_text}</span>|
  end

  defp inline_value(%{value: value} = assigns) when is_map(value) or is_list(value) do
    summary =
      case value do
        m when is_map(m) -> "{#{map_size(m)} fields}"
        l when is_list(l) -> "[#{length(l)} items]"
      end

    assigns = assign(assigns, :summary, summary)

    ~H|<span class="text-sm font-mono">{@summary}</span>|
  end

  defp inline_value(%{value: value} = assigns) do
    assigns = assign(assigns, :value_text, to_string(value))

    ~H|<span class="text-sm font-mono">{@value_text}</span>|
  end

  attr :value, :any, default: nil

  defp severity_badge(assigns) do
    variant = severity_variant(assigns.value)
    label = severity_label(assigns.value)

    assigns = assigns |> assign(:variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp severity_variant(value) do
    case normalize_severity(value) do
      s when s in ["emergency", "critical"] -> "error"
      s when s in ["warning"] -> "warning"
      s when s in ["info"] -> "info"
      _ -> "ghost"
    end
  end

  defp severity_label(nil), do: "—"
  defp severity_label(""), do: "—"
  defp severity_label(value) when is_binary(value), do: value
  defp severity_label(value), do: to_string(value)

  defp normalize_severity(nil), do: ""
  defp normalize_severity(v) when is_binary(v), do: v |> String.trim() |> String.downcase()
  defp normalize_severity(v), do: v |> to_string() |> normalize_severity()

  attr :value, :any, default: nil

  defp status_badge(assigns) do
    variant = status_variant(assigns.value)
    label = status_label(assigns.value)

    assigns = assigns |> assign(:variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp status_variant(value) do
    case normalize_status(value) do
      "pending" -> "warning"
      "acknowledged" -> "info"
      "resolved" -> "success"
      "escalated" -> "error"
      "suppressed" -> "ghost"
      _ -> "ghost"
    end
  end

  defp status_label(nil), do: "—"
  defp status_label(""), do: "—"
  defp status_label(value) when is_binary(value), do: String.capitalize(value)
  defp status_label(value), do: value |> to_string() |> String.capitalize()

  defp normalize_status(nil), do: ""
  defp normalize_status(v) when is_binary(v), do: String.downcase(v)
  defp normalize_status(v), do: v |> to_string() |> normalize_status()

  defp format_timestamp(alert) do
    ts = Map.get(alert, "triggered_at") || Map.get(alert, "timestamp")

    case parse_timestamp(ts) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      _ -> ts || "—"
    end
  end

  defp parse_timestamp(nil), do: :error

  defp parse_timestamp(%DateTime{} = dt), do: {:ok, dt}

  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp parse_timestamp(_), do: :error

  defp has_value?(map, key) do
    case Map.get(map, key) do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  defp stateful_incident?(alert) when is_map(alert) do
    metadata = Map.get(alert, "metadata") || %{}

    is_map(incident_diagnostics(alert)) and
      (Map.has_key?(metadata, "incident_rule_id") or Map.has_key?(metadata, "incident_diagnostics"))
  end

  defp stateful_incident?(_), do: false

  defp incident_diagnostics(alert) when is_map(alert) do
    metadata = Map.get(alert, "metadata") || %{}
    diagnostic_value(metadata, ["incident_diagnostics"]) || %{}
  end

  defp incident_diagnostics(_), do: %{}

  defp first_sample(diagnostics, sample_key) do
    diagnostics
    |> diagnostic_value(["samples", sample_key])
    |> case do
      [sample | _] when is_map(sample) -> sample
      _ -> %{}
    end
  end

  defp window_display(diagnostics) do
    case diagnostic_value(diagnostics, ["window_seconds"]) do
      nil -> nil
      seconds -> "#{seconds}s"
    end
  end

  defp process_display(process) when is_map(process) do
    diagnostic_value(process, ["command"]) || diagnostic_value(process, ["name"])
  end

  defp process_display(_), do: nil

  defp container_display(container) when is_map(container) do
    diagnostic_value(container, ["name"]) || diagnostic_value(container, ["id"])
  end

  defp container_display(_), do: nil

  defp image_display(container) when is_map(container) do
    repository = diagnostic_value(container, ["image_repository"])
    tag = diagnostic_value(container, ["image_tag"])

    cond do
      is_binary(repository) and is_binary(tag) -> "#{repository}:#{tag}"
      is_binary(repository) -> repository
      true -> diagnostic_value(container, ["image"])
    end
  end

  defp image_display(_), do: nil

  defp kubernetes_display(kubernetes) when is_map(kubernetes) do
    namespace = diagnostic_value(kubernetes, ["namespace"])
    pod = diagnostic_value(kubernetes, ["pod"])

    cond do
      is_binary(namespace) and is_binary(pod) -> "#{namespace}/#{pod}"
      is_binary(pod) -> pod
      is_binary(namespace) -> namespace
      true -> nil
    end
  end

  defp kubernetes_display(_), do: nil

  defp attribution_display(kubernetes) when is_map(kubernetes) do
    status = diagnostic_value(kubernetes, ["attribution_status"])
    missing = diagnostic_value(kubernetes, ["missing"])

    case {status, missing} do
      {nil, _} -> nil
      {value, []} -> value
      {value, nil} -> value
      {value, missing_values} -> "#{value} (missing #{display_diagnostic_value(missing_values)})"
    end
  end

  defp attribution_display(_), do: nil

  defp display_diagnostic_value(value) when value in [nil, ""], do: "—"
  defp display_diagnostic_value(value) when is_binary(value), do: value
  defp display_diagnostic_value(value) when is_boolean(value), do: to_string(value)
  defp display_diagnostic_value(value) when is_number(value), do: to_string(value)

  defp display_diagnostic_value(value) when is_list(value) do
    Enum.map_join(value, ", ", &display_diagnostic_value/1)
  end

  defp display_diagnostic_value(value) when is_map(value) do
    Enum.map_join(value, ", ", fn {key, item} ->
      "#{field_label(to_string(key))}: #{display_diagnostic_value(item)}"
    end)
  end

  defp diagnostic_value(data, [key]) when is_map(data), do: Map.get(data, key) || Map.get(data, diagnostic_atom_key(key))

  defp diagnostic_value(data, [key | rest]) when is_map(data) do
    case diagnostic_value(data, [key]) do
      %{} = nested -> diagnostic_value(nested, rest)
      _ -> nil
    end
  end

  defp diagnostic_value(_, _), do: nil

  defp diagnostic_atom_key("incident_diagnostics"), do: :incident_diagnostics
  defp diagnostic_atom_key("samples"), do: :samples
  defp diagnostic_atom_key("processes"), do: :processes
  defp diagnostic_atom_key("containers"), do: :containers
  defp diagnostic_atom_key("kubernetes"), do: :kubernetes
  defp diagnostic_atom_key("rule_name"), do: :rule_name
  defp diagnostic_atom_key("group_key"), do: :group_key
  defp diagnostic_atom_key("window_count"), do: :window_count
  defp diagnostic_atom_key("threshold"), do: :threshold
  defp diagnostic_atom_key("window_seconds"), do: :window_seconds
  defp diagnostic_atom_key("first_seen_at"), do: :first_seen_at
  defp diagnostic_atom_key("last_seen_at"), do: :last_seen_at
  defp diagnostic_atom_key("representative_event_ids"), do: :representative_event_ids
  defp diagnostic_atom_key("command"), do: :command
  defp diagnostic_atom_key("name"), do: :name
  defp diagnostic_atom_key("id"), do: :id
  defp diagnostic_atom_key("image"), do: :image
  defp diagnostic_atom_key("image_repository"), do: :image_repository
  defp diagnostic_atom_key("image_tag"), do: :image_tag
  defp diagnostic_atom_key("namespace"), do: :namespace
  defp diagnostic_atom_key("pod"), do: :pod
  defp diagnostic_atom_key("attribution_status"), do: :attribution_status
  defp diagnostic_atom_key("missing"), do: :missing
  defp diagnostic_atom_key(_), do: :__unknown__

  defp blank?(value), do: value in [nil, ""]

  defp field_label(field) when is_binary(field), do: humanize_field(field)
  defp field_label(field), do: to_string(field)

  defp humanize_field(field) when is_binary(field) do
    field
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp escape_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp escape_value(other), do: escape_value(to_string(other))

  defp format_error(%Jason.DecodeError{} = err), do: Exception.message(err)
  defp format_error(%ArgumentError{} = err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
