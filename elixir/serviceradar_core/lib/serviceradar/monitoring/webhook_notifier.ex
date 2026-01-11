defmodule ServiceRadar.Monitoring.WebhookNotifier do
  @moduledoc """
  Webhook notification service for sending alerts to external systems.

  Port of Go core's alerts/webhook.go. Supports:
  - Configurable webhook endpoints
  - Custom headers and templates
  - Cooldown to prevent alert storms
  - Node/service state tracking

  ## Configuration

  Configure in your runtime.exs or config.exs:

      config :serviceradar_core, ServiceRadar.Monitoring.WebhookNotifier,
        enabled: true,
        webhooks: [
          %{
            url: "https://hooks.slack.com/...",
            headers: [%{key: "Authorization", value: "Bearer token"}],
            cooldown: :timer.minutes(5),
            template: nil  # Use default JSON payload
          },
          %{
            url: "https://discord.com/api/webhooks/...",
            headers: [],
            cooldown: :timer.minutes(5),
            template: nil
          }
        ]

  ## Usage

      # Send an alert
      alert = %WebhookNotifier.Alert{
        level: :warning,
        title: "Node Offline",
        message: "Agent agent-1 is not responding",
        gateway_id: "gateway-1",
        details: %{"last_seen" => "2025-01-01T00:00:00Z"}
      }

      WebhookNotifier.send_alert(alert)
  """

  use GenServer

  require Logger

  @default_timeout :timer.seconds(10)
  @default_cooldown :timer.minutes(5)

  # Alert level type
  @type alert_level :: :info | :warning | :error

  # Alert struct matching Go's WebhookAlert
  defmodule Alert do
    @moduledoc """
    Webhook alert payload structure.
    """
    @type t :: %__MODULE__{
            level: :info | :warning | :error,
            title: String.t(),
            message: String.t(),
            timestamp: String.t(),
            gateway_id: String.t(),
            service_name: String.t() | nil,
            details: map()
          }

    defstruct [
      :level,
      :title,
      :message,
      :timestamp,
      :gateway_id,
      :service_name,
      details: %{}
    ]
  end

  # Webhook config
  defmodule WebhookConfig do
    @moduledoc false
    @type t :: %__MODULE__{
            url: String.t(),
            headers: [%{key: String.t(), value: String.t()}],
            cooldown: non_neg_integer(),
            template: String.t() | nil,
            enabled: boolean()
          }

    defstruct [
      :url,
      headers: [],
      cooldown: :timer.minutes(5),
      template: nil,
      enabled: true
    ]
  end

  # GenServer state
  defmodule State do
    @moduledoc false
    defstruct [
      :webhooks,
      :http_client,
      last_alert_times: %{},
      node_down_states: %{},
      service_alert_states: %{}
    ]
  end

  # Client API

  @doc """
  Start the webhook notifier GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Send an alert through all configured webhooks.

  Returns `:ok` if at least one webhook succeeded, or `{:error, reason}` if all failed.
  """
  @spec send_alert(Alert.t()) :: :ok | {:error, term()}
  def send_alert(%Alert{} = alert) do
    GenServer.call(__MODULE__, {:send_alert, alert}, @default_timeout)
  catch
    :exit, {:noproc, _} ->
      Logger.warning("WebhookNotifier not running, skipping alert: #{alert.title}")
      {:error, :not_running}
  end

  @doc """
  Check if the notifier is enabled and has configured webhooks.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    GenServer.call(__MODULE__, :enabled?)
  catch
    :exit, {:noproc, _} -> false
  end

  @doc """
  Mark a gateway as recovered (clears the node down state).
  """
  @spec mark_gateway_recovered(String.t()) :: :ok
  def mark_gateway_recovered(gateway_id) do
    GenServer.cast(__MODULE__, {:mark_gateway_recovered, gateway_id})
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc """
  Mark a service as recovered.
  """
  @spec mark_service_recovered(String.t()) :: :ok
  def mark_service_recovered(service_id) do
    GenServer.cast(__MODULE__, {:mark_service_recovered, service_id})
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc """
  Get notifier statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  catch
    :exit, {:noproc, _} -> %{error: :not_running}
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])

    webhooks =
      Keyword.get(config, :webhooks, [])
      |> Enum.map(&build_webhook_config/1)
      |> Enum.filter(& &1.enabled)

    http_client = Keyword.get(opts, :http_client, Req)

    if Enum.empty?(webhooks) do
      Logger.info("WebhookNotifier started with no configured webhooks")
    else
      Logger.info("WebhookNotifier started with #{length(webhooks)} webhook(s)")
    end

    {:ok, %State{webhooks: webhooks, http_client: http_client}}
  end

  @impl true
  def handle_call({:send_alert, alert}, _from, state) do
    if Enum.empty?(state.webhooks) do
      {:reply, {:error, :no_webhooks_configured}, state}
    else
      {result, new_state} = do_send_alert(alert, state)
      {:reply, result, new_state}
    end
  end

  @impl true
  def handle_call(:enabled?, _from, state) do
    {:reply, not Enum.empty?(state.webhooks), state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      webhook_count: length(state.webhooks),
      node_down_count: map_size(state.node_down_states),
      service_alert_count: map_size(state.service_alert_states),
      cooldown_entries: map_size(state.last_alert_times)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:mark_gateway_recovered, gateway_id}, state) do
    Logger.debug("Marked gateway #{gateway_id} as recovered")
    new_states = Map.put(state.node_down_states, gateway_id, false)
    {:noreply, %{state | node_down_states: new_states}}
  end

  @impl true
  def handle_cast({:mark_service_recovered, service_id}, state) do
    Logger.debug("Marked service #{service_id} as recovered")
    new_states = Map.put(state.service_alert_states, service_id, false)
    {:noreply, %{state | service_alert_states: new_states}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp build_webhook_config(config) when is_map(config) do
    %WebhookConfig{
      url: Map.get(config, :url) || Map.get(config, "url"),
      headers: Map.get(config, :headers, []) || Map.get(config, "headers", []),
      cooldown:
        Map.get(config, :cooldown, @default_cooldown) ||
          Map.get(config, "cooldown", @default_cooldown),
      template: Map.get(config, :template) || Map.get(config, "template"),
      enabled: Map.get(config, :enabled, true)
    }
  end

  defp do_send_alert(alert, state) do
    # Ensure timestamp is set
    alert = ensure_timestamp(alert)

    # Check for duplicate "Node Offline" alert
    state =
      if alert.title == "Node Offline" do
        if Map.get(state.node_down_states, alert.gateway_id) do
          Logger.debug("Skipping duplicate 'Node Offline' alert for node: #{alert.gateway_id}")
          throw({:duplicate, state})
        else
          new_states = Map.put(state.node_down_states, alert.gateway_id, true)
          %{state | node_down_states: new_states}
        end
      else
        state
      end

    # Send to each webhook
    results =
      Enum.map(state.webhooks, fn webhook ->
        send_to_webhook(alert, webhook, state)
      end)

    # Collect errors
    errors = Enum.filter(results, fn {result, _} -> result == :error end)

    # Update cooldown times
    alert_key = {alert.gateway_id, alert.title, alert.service_name || ""}

    new_last_alert_times =
      Map.put(state.last_alert_times, alert_key, System.monotonic_time(:millisecond))

    state = %{state | last_alert_times: new_last_alert_times}

    if Enum.empty?(errors) or length(errors) < length(state.webhooks) do
      {:ok, state}
    else
      {{:error, errors}, state}
    end
  catch
    {:duplicate, state} -> {:ok, state}
  end

  defp ensure_timestamp(%Alert{timestamp: nil} = alert) do
    %{alert | timestamp: DateTime.utc_now() |> DateTime.to_iso8601()}
  end

  defp ensure_timestamp(alert), do: alert

  defp send_to_webhook(alert, webhook, state) do
    # Check cooldown
    alert_key = {alert.gateway_id, alert.title, alert.service_name || ""}

    case check_cooldown(alert_key, webhook.cooldown, state.last_alert_times) do
      :ok ->
        payload = prepare_payload(alert, webhook.template)
        do_http_post(webhook.url, payload, webhook.headers, state.http_client)

      {:error, :cooldown} ->
        Logger.debug(
          "Alert '#{alert.title}' for gateway '#{alert.gateway_id}' is within cooldown period"
        )

        {:error, :cooldown}
    end
  end

  defp check_cooldown(_key, cooldown, _last_times) when cooldown <= 0, do: :ok

  defp check_cooldown(key, cooldown, last_times) do
    case Map.get(last_times, key) do
      nil ->
        :ok

      last_time ->
        now = System.monotonic_time(:millisecond)

        if now - last_time < cooldown do
          {:error, :cooldown}
        else
          :ok
        end
    end
  end

  defp prepare_payload(alert, nil) do
    # Default JSON payload
    %{
      level: to_string(alert.level),
      title: alert.title,
      message: alert.message,
      timestamp: alert.timestamp,
      gateway_id: alert.gateway_id,
      service_name: alert.service_name,
      details: alert.details
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp prepare_payload(alert, template) when is_binary(template) do
    # Apply EEx template
    try do
      result = EEx.eval_string(template, alert: alert)
      Jason.decode!(result)
    rescue
      e ->
        Logger.error("Template evaluation failed: #{inspect(e)}")
        prepare_payload(alert, nil)
    end
  end

  defp do_http_post(url, payload, headers, http_client) do
    headers_map =
      headers
      |> Enum.map(fn h -> {h[:key] || h["key"], h[:value] || h["value"]} end)
      |> Map.new()
      |> Map.put_new("content-type", "application/json")

    case http_client.post(url,
           json: payload,
           headers: headers_map,
           receive_timeout: @default_timeout
         ) do
      {:ok, %{status: status}} when status >= 200 and status < 300 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Webhook returned non-2xx status: #{status}, body: #{inspect(body)}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.error("Webhook request failed: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("Webhook request exception: #{inspect(e)}")
      {:error, e}
  end
end
