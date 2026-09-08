defmodule ServiceRadar.Notifications.Callbacks.PagerDuty do
  @moduledoc """
  Verifies a PagerDuty v3 webhook and maps it onto an alert transition
  (task 4.3.3).

  ## PagerDuty is not Slack, in three ways that matter

  **The signed material is the body alone.** No timestamp, no path, no method,
  no separator - the exact request bytes and nothing else. The `v1=` prefix
  lives only in the header value and is not part of the signed input. Copying
  either the northbound `"<timestamp>.<body>"` scheme or the Slack
  `"v0:<ts>:<body>"` scheme here produces a digest that never matches.

  **The header carries a list.** `X-PagerDuty-Signature` is comma-separated so a
  secret can be rotated without dropping deliveries, and any element may match.
  Elements that do not start with `v1=` are **skipped rather than rejected**, so
  a future `v2=` alongside a `v1=` still verifies. Matching uses
  `Primitives.any_equal?/2`, which folds over every candidate instead of
  returning on the first hit - `Enum.any?/2` would leak the matching position
  through timing.

  **There is no transport-level replay defence.** PagerDuty sends no timestamp
  header, so there is nothing outside the body to enforce a window against. What
  exists is `event.occurred_at` *inside* the signed body, which an attacker
  cannot alter without breaking the HMAC - so bounding it does limit replay.
  The bound is deliberately wide (30 minutes): PagerDuty retries roughly four
  times with backoff over ~20 minutes, and a Stripe-style 300 s window would
  reject PagerDuty's own legitimate retries and get the subscription
  `temporarily_disabled`. The real defence against a replayed distinct event is
  deduping on `event.id`.

  ## Which secret

  One signing secret per **webhook subscription**, and the inbound request names
  its subscription in `X-Webhook-Subscription`. That is the analogue of Slack's
  `api_app_id`, so it resolves through the same
  `ServiceRadar.Notifications.Callbacks.AppRegistry` with the subscription id as
  `external_app_id`.

  The secret is returned **only** in the response to
  `POST /webhook_subscriptions`, as `delivery_method.secret`, and is never
  returned again. A subscription whose secret was not captured at creation is
  unrecoverable and must be deleted and recreated. It is a different secret from
  the Events API v2 `routing_key` the outbound path uses.

  ## Which events, and which have no inverse

  `incident.acknowledged` and `incident.resolved` map onto the alert transitions
  of the same name. Two others deliberately do not:

    * `incident.unacknowledged` and `incident.reopened` have no inverse -
      `ActionRedemption.apply_native/2` accepts only acknowledge, snooze and
      resolve. They are refused explicitly rather than ignored, because
      subscribing to an event whose handler silently drops it is how an operator
      concludes the integration works when half of it does not.
    * There is no `incident.snoozed` in the v3 catalogue at all, so a PagerDuty
      snooze cannot round-trip and snooze stays on the signed-link path.
  """

  @behaviour ServiceRadar.Notifications.Callbacks.Signature

  alias ServiceRadar.Notifications.Callbacks.Primitives

  @signature_header "x-pagerduty-signature"
  @subscription_header "x-webhook-subscription"

  @signature_prefix "v1="

  # Wider than PagerDuty's own retry span. See the moduledoc: a tighter bound
  # rejects legitimate retries and disables the subscription.
  @occurred_at_tolerance_seconds 1800

  # The two event types that have an inverse in the redemption path.
  @actions %{
    "incident.acknowledged" => :acknowledge,
    "incident.resolved" => :resolve
  }

  # Recognised, deliberately unsupported. Named so the refusal is specific.
  @no_inverse ~w(incident.unacknowledged incident.reopened)

  @impl true
  def provider_key, do: :pagerduty

  @doc "The headers this verifier reads, for route and fixture assertions."
  @spec headers() :: %{signature: String.t(), subscription: String.t()}
  def headers, do: %{signature: @signature_header, subscription: @subscription_header}

  @doc "The bound enforced on the in-body `event.occurred_at`."
  @spec occurred_at_tolerance_seconds() :: pos_integer()
  def occurred_at_tolerance_seconds, do: @occurred_at_tolerance_seconds

  @doc """
  Signs a body as PagerDuty would. Used by tests and by subscription setup
  verification.
  """
  @spec sign(binary(), String.t()) :: String.t()
  def sign(raw_body, secret),
    do: @signature_prefix <> Primitives.hmac_sha256_hex(secret, raw_body)

  @impl true
  @spec verify(binary(), Primitives.headers(), String.t(), keyword()) ::
          :ok | {:error, atom()}
  def verify(raw_body, headers, secret, opts \\ [])

  def verify(raw_body, headers, secret, opts) when is_binary(secret) and secret != "" do
    with {:ok, body} <-
           Primitives.require_raw_body(raw_body, Keyword.get(opts, :content_length)),
         {:ok, candidates} <- presented_signatures(headers) do
      # The body ALONE. No timestamp, no separator, no prefix.
      expected = Primitives.hmac_sha256_hex(secret, body)

      if Primitives.any_equal?(candidates, expected) do
        check_occurred_at(body, opts)
      else
        {:error, :invalid_signature}
      end
    end
  end

  def verify(_raw_body, _headers, _secret, _opts), do: {:error, :missing_key_material}

  @impl true
  @doc """
  Reads the event PagerDuty posted.

  The subscription id comes from a header rather than the body, because it is
  what selects the secret and must be readable before the body is trusted.
  """
  @spec decode_interaction(map()) :: {:ok, map()} | {:error, atom()}
  def decode_interaction(%{} = request) do
    with {:ok, decoded} <-
           decode_body(Map.get(request, :params) || %{}, Map.get(request, :raw_body) || ""),
         %{"event" => %{} = event} <- decoded,
         {:ok, event_id} <- non_empty(event, "id", :missing_event_id),
         {:ok, event_type} <- non_empty(event, "event_type", :missing_event_type) do
      data = Map.get(event, "data") || %{}

      {:ok,
       %{
         # The subscription id is the key selector, so it is named `app_id` to
         # match the field the controller resolves on for every provider.
         app_id: subscription_id(Map.get(request, :headers) || %{}),
         event_id: event_id,
         event_type: event_type,
         occurred_at: Map.get(event, "occurred_at"),
         agent_id: get_in(event, ["agent", "id"]),
         incident_id: Map.get(data, "id"),
         incident_key: Map.get(data, "incident_key")
       }}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_payload}
    end
  end

  @doc """
  Reads the subscription id the request names, so the controller can select a
  secret before trusting the body.
  """
  @spec subscription_id(map() | Primitives.headers()) :: String.t() | nil
  def subscription_id(source) do
    case Primitives.header(source, @subscription_header) do
      value when is_binary(value) and value != "" -> String.trim(value)
      _absent -> nil
    end
  end

  @impl true
  @doc """
  Maps a decoded event onto the capability the redemption path accepts.

  `incident_key` is our own `dedup_key`, which the shipping PagerDuty document
  sets to the alert id - so it is read back rather than the PagerDuty incident id
  being looked up over the API. An event whose `incident_key` is empty came from
  an incident ServiceRadar did not open, and is refused rather than guessed at.
  """
  @spec capability(map()) :: {:ok, map()} | {:error, atom()}
  def capability(%{event_type: event_type} = event) do
    with {:ok, action} <- action(event_type),
         {:ok, alert_id} <- correlation(event) do
      {:ok,
       %{
         action: action,
         alert_id: alert_id,
         delivery_id: nil,
         external_principal: principal(event),
         app_id: Map.get(event, :app_id),
         # PagerDuty has no transport-level replay defence, so its own event id
         # is what makes a redelivery idempotent. A ULID, unique per event.
         event_id: Map.get(event, :event_id)
       }}
    end
  end

  def capability(_event), do: {:error, :invalid_payload}

  defp action(event_type) do
    cond do
      Map.has_key?(@actions, event_type) -> {:ok, Map.fetch!(@actions, event_type)}
      event_type in @no_inverse -> {:error, :event_type_has_no_inverse}
      true -> {:error, :unsupported_event_type}
    end
  end

  defp correlation(%{incident_key: key}) when is_binary(key) and key != "", do: {:ok, key}
  defp correlation(_event), do: {:error, :missing_incident_key}

  defp principal(%{agent_id: agent_id}) when is_binary(agent_id) and agent_id != "",
    do: "pagerduty:" <> agent_id

  defp principal(_event), do: "pagerduty"

  # --- verification helpers --------------------------------------------------

  defp presented_signatures(headers) do
    case Primitives.header(headers, @signature_header) do
      value when is_binary(value) and value != "" ->
        candidates =
          value
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          # A future `v2=` element alongside a `v1=` must not fail the request.
          |> Enum.filter(&String.starts_with?(&1, @signature_prefix))
          |> Enum.map(
            &binary_part(
              &1,
              byte_size(@signature_prefix),
              byte_size(&1) - byte_size(@signature_prefix)
            )
          )

        case candidates do
          [] -> {:error, :unsupported_signature_version}
          candidates -> {:ok, candidates}
        end

      _absent ->
        {:error, :missing_signature}
    end
  end

  # Bounds replay using the only clock inside the signed material. Not a
  # transport guarantee - see the moduledoc - and deliberately wide.
  defp check_occurred_at(body, opts) do
    with {:ok, decoded} <- decode_json(body),
         occurred_at when is_binary(occurred_at) <- get_in(decoded, ["event", "occurred_at"]),
         {:ok, timestamp, _offset} <- DateTime.from_iso8601(occurred_at) do
      now = Keyword.get(opts, :now) || DateTime.utc_now()

      tolerance =
        Keyword.get(opts, :occurred_at_tolerance_seconds, @occurred_at_tolerance_seconds)

      if Primitives.within_tolerance?(timestamp, now, tolerance) do
        :ok
      else
        {:error, :stale_timestamp}
      end
    else
      # A signed body with no parseable occurred_at is still authentic. Refusing
      # it would reject a future payload shape that PagerDuty signed correctly,
      # so the bound is skipped rather than the request failed.
      _absent -> :ok
    end
  end

  defp decode_body(params, raw_body) do
    case params do
      %{"event" => _event} = decoded -> {:ok, decoded}
      _other -> decode_json(raw_body)
    end
  end

  defp decode_json(body) when is_binary(body) and body != "" do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _other -> {:error, :invalid_payload}
    end
  end

  defp decode_json(_body), do: {:error, :invalid_payload}

  defp non_empty(map, key, error) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _absent -> {:error, error}
    end
  end
end
