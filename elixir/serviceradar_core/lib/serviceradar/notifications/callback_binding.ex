defmodule ServiceRadar.Notifications.CallbackBinding do
  @moduledoc """
  Binds a verified native callback to the delivery that originated it.

  Provider signatures authenticate a request, but their signed bodies still
  contain provider-controlled identifiers. Before an alert action is applied,
  this module proves that those identifiers resolve to one successful, non-test
  delivery, that the delivery belongs to the named alert, and that its channel
  uses the same provider. Slack additionally binds the signed app and action ids
  to the channel configuration and rendered control.

  PagerDuty carries no ServiceRadar delivery id. Its `incident_key` is the
  `dedup_key` sent as both the alert correlation and the persisted external
  correlation id, so that pair is resolved to the newest matching PagerDuty
  delivery and the concrete delivery id is added to the capability.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Notifications.NotificationDelivery

  require Ash.Query

  @rejections [
    :callback_action_mismatch,
    :callback_channel_mismatch,
    :callback_delivery_mismatch,
    :callback_delivery_not_found,
    :callback_provider_mismatch,
    :invalid_callback_binding
  ]

  @doc "Binds a verified callback capability to its persisted delivery."
  @spec bind(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def bind(capability, opts \\ [])

  def bind(capability, opts) when is_map(capability) and is_list(opts) do
    actor = Keyword.get(opts, :actor) || SystemActor.system(:notification_callback_binding)
    loader = Keyword.get(opts, :load_delivery, &load_delivery/3)

    with {:ok, provider_key} <- provider_key(Map.get(capability, :provider_key)),
         {:ok, delivery} <- loader.(capability, provider_key, actor),
         :ok <- delivery_present?(delivery),
         :ok <- delivery_matches?(delivery, capability),
         {:ok, channel} <- delivery_channel(delivery),
         :ok <- provider_matches?(channel, provider_key),
         :ok <- provider_binding(provider_key, capability, delivery, channel) do
      {:ok, Map.put(capability, :delivery_id, to_string(delivery.id))}
    end
  end

  def bind(_capability, _opts), do: {:error, :invalid_callback_binding}

  @doc "Whether a binding refusal is permanent and must not retry as a database fault."
  @spec rejection?(term()) :: boolean()
  def rejection?(reason), do: reason in @rejections

  defp load_delivery(%{delivery_id: delivery_id}, "slack", actor)
       when is_binary(delivery_id) and delivery_id != "" do
    NotificationDelivery
    |> Ash.Query.for_read(:by_id, %{id: delivery_id})
    |> Ash.Query.filter(state == :sent and is_test == false)
    |> Ash.Query.load(channel: [:provider])
    |> Ash.read_one(actor: actor)
  end

  defp load_delivery(%{alert_id: alert_id}, "pagerduty", actor)
       when is_binary(alert_id) and alert_id != "" do
    NotificationDelivery
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      alert_id == ^alert_id and external_correlation_id == ^alert_id and state == :sent and
        is_test == false and
        channel.provider.provider_key == "pagerduty"
    )
    |> Ash.Query.load(channel: [:provider])
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(actor: actor)
  end

  defp load_delivery(_capability, _provider_key, _actor), do: {:error, :invalid_callback_binding}

  defp delivery_present?(nil), do: {:error, :callback_delivery_not_found}
  defp delivery_present?(%{id: id}) when not is_nil(id), do: :ok
  defp delivery_present?(_delivery), do: {:error, :callback_delivery_not_found}

  defp delivery_matches?(delivery, capability) do
    alert_matches? = same_id?(Map.get(delivery, :alert_id), Map.get(capability, :alert_id))
    sent? = Map.get(delivery, :state) in [:sent, "sent"]
    real_delivery? = Map.get(delivery, :is_test) == false

    delivery_id_matches? =
      case Map.get(capability, :delivery_id) do
        nil -> true
        delivery_id -> same_id?(Map.get(delivery, :id), delivery_id)
      end

    if alert_matches? and delivery_id_matches? and sent? and real_delivery? do
      :ok
    else
      {:error, :callback_delivery_mismatch}
    end
  end

  defp delivery_channel(%{channel: %{provider: %{provider_key: _provider_key}} = channel}),
    do: {:ok, channel}

  defp delivery_channel(_delivery), do: {:error, :callback_channel_mismatch}

  defp provider_matches?(%{provider: %{provider_key: provider_key}}, expected) do
    if to_string(provider_key) == expected,
      do: :ok,
      else: {:error, :callback_provider_mismatch}
  end

  defp provider_binding("slack", capability, _delivery, channel) do
    expected_action_id = "notification_" <> to_string(Map.get(capability, :action))
    config = Map.get(channel, :config) || %{}

    cond do
      not non_empty?(Map.get(capability, :app_id)) ->
        {:error, :invalid_callback_binding}

      Map.get(config, "api_app_id") != Map.get(capability, :app_id) ->
        {:error, :callback_channel_mismatch}

      Map.get(capability, :action_id) != expected_action_id ->
        {:error, :callback_action_mismatch}

      true ->
        :ok
    end
  end

  defp provider_binding("pagerduty", capability, delivery, _channel) do
    # A PagerDuty webhook subscription is account-scoped and is deliberately
    # not the outbound Events API routing key, so there is no honest
    # subscription-to-channel equality to assert. The signed incident_key is
    # instead bound to a successful PagerDuty delivery above; app_id still has
    # to be present because it selected the registered verification secret.
    if non_empty?(Map.get(capability, :app_id)) and
         same_id?(Map.get(delivery, :external_correlation_id), Map.get(capability, :alert_id)) do
      :ok
    else
      {:error, :callback_delivery_mismatch}
    end
  end

  defp provider_key(provider_key) when provider_key in [:slack, "slack"], do: {:ok, "slack"}

  defp provider_key(provider_key) when provider_key in [:pagerduty, "pagerduty"],
    do: {:ok, "pagerduty"}

  defp provider_key(_provider_key), do: {:error, :invalid_callback_binding}

  defp same_id?(left, right) when is_binary(left) and is_binary(right), do: left == right

  defp same_id?(left, right) when not is_nil(left) and not is_nil(right),
    do: to_string(left) == to_string(right)

  defp same_id?(_left, _right), do: false

  defp non_empty?(value), do: is_binary(value) and value != ""
end
