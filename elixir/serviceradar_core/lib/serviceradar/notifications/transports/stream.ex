defmodule ServiceRadar.Notifications.Transports.Stream do
  @moduledoc """
  The built-in `:stream` provider: publish the canonical notification envelope to
  an RBAC-scoped topic (design D10).

  `:stream` is a `provider_type`, not a fourth extensibility tier - an operator
  cannot author one, and its `NotificationProvider` row ships seeded. What makes
  it a provider at all rather than a side door is that the firehose then
  traverses the same routing, suppression, redaction, and audit path as Slack.
  Concretely, a suppressed dispatch to a `:stream` channel publishes **no**
  envelope and writes a `NotificationDelivery` row with `state: :suppressed`; the
  Delivery Log is where that shows up, never the stream. Nothing publishes a
  "suppressed" envelope under a different name (task 4.2.1a) - and nothing in
  this module can, because suppression is decided before a transport is called.

  ## The envelope carries no acknowledgement capability (design D7, C2)

  Every other provider's rendered notification carries `Acknowledge`, `Snooze`,
  and `Resolve` links bearing a **single-use capability token minted for one
  delivery**. The firehose is a broadcast to every subscriber authorised for the
  topic, so embedding one there hands an acknowledgement credential to every
  listener at once - and the first subscriber to click it consumes it, so the
  rest see a dead link and the alert is acknowledged by an unattributable actor.

  Two independent mechanisms enforce the exemption, because one is not enough:

    1. `Notifications.Renderer` is called with `include_action_links?: false` for
       a `:stream` channel, which drops the three links from the variable context
       so even a hand-written template cannot reintroduce one.
    2. This transport strips them again from the payload it is handed
       (`strip_action_links/1`), so a payload that arrived from anywhere else -
       a replay, a fixture, a future caller that forgets option 1 - still cannot
       put a capability token on the wire.

  Belt and braces is deliberate: option 1 lives in the caller and option 2 is the
  invariant this module owns, and an invariant that depends on its caller
  remembering is not an invariant.

  ## Topics

  `topic/1` returns `#{inspect("notifications:stream")}` for the firehose, or
  `notifications:stream:<suffix>` when the channel configures one. The topic
  itself grants nothing: **web-ng authorises the join** on
  `notifications.stream.subscribe` and filters the envelope to what the
  subscriber may see (task 4.2.2). This module publishes; it does not authorise,
  and it must not be read as though placing an envelope on a topic were an
  authorisation decision.

  ## Live and durable delivery seams

  Delivery goes through `opts[:broadcast]`, a `fun(topic, envelope)` defaulting
  to `default_publish/2`. The default persists the envelope to JetStream first
  and then broadcasts it over Phoenix.PubSub. Tests inject the seam, so every
  test here is `async: true` with no PubSub process and no broker.

  This module owns publication, not subscriber cursors. Web-ng derives a durable
  consumer name from trusted tenant and user identity plus the topic and a
  client identifier. A signed, identity-bound cursor can make a reconnect's next
  stream sequence authoritative; without one, web-ng resumes the durable ACK
  position. It acknowledges each JetStream record only after a fresh
  authorization check, an authorized channel push, a separate cursor-control
  push, and the client's exact-cursor acknowledgement. Keeping cursor creation
  on the subscriber side prevents transport delivery from mistaking publication
  for authorization.

  ## Purity

  Envelope construction is pure and separately callable (`envelope/2`), so the
  shape can be asserted without publishing anything. The clock is an input
  (`opts[:now]`), matching `Notifications.Renderer`.
  """

  @behaviour ServiceRadar.Notifications.Transport

  alias ServiceRadar.Automation.Northbound.ActionRedaction
  alias ServiceRadar.Notifications.StreamPublisher
  alias ServiceRadar.Notifications.Transport
  alias ServiceRadar.Notifications.Transport.Request
  alias ServiceRadar.Notifications.Transport.Result
  alias ServiceRadar.Notifications.Transports.HTTP

  require Logger

  @envelope_schema "serviceradar.notification_envelope.v1"

  @firehose_topic "notifications:stream"

  # A topic suffix becomes part of a Phoenix Channel topic, so it is restricted
  # to a charset that cannot smuggle a wildcard or a separator into a topic an
  # operator was not granted.
  @topic_suffix_regex ~r/\A[a-z0-9][a-z0-9_:-]{0,63}\z/

  @default_pubsub ServiceRadar.PubSub

  @broadcast_event :notification_envelope

  # The three capability-bearing actions (design D7) plus the key names the
  # first-party renderers emit them under. `links.alert` is a plain deep link and
  # deliberately survives: a subscriber needs somewhere to go, and that URL
  # carries no token.
  @action_names ~w(acknowledge snooze resolve)
  @action_link_keys ~w(
    acknowledge
    snooze
    resolve
    acknowledge_url
    snooze_url
    resolve_url
    action_links
    capability_token
    ack_token
  )

  # Keys that mark a provider's interactive control. Both string and atom forms,
  # because a payload can reach here from a renderer (atoms) or from a decoded
  # fixture (strings), and a check that only covered one would be exactly the
  # kind of half-guard this exists to avoid.
  @interactive_control_keys ["action_id", :action_id, "custom_id", :custom_id]

  @type broadcast :: (String.t(), map() -> :ok | {:ok, term()} | {:error, term()})

  @impl true
  @spec capabilities() :: [Transport.capability()]
  def capabilities, do: [:send, :test]

  @impl true
  @spec validate_config(term()) :: :ok | {:error, [Transport.config_error()]}
  def validate_config(config) when is_map(config) do
    config = normalize_map(config)

    case topic_errors(config) ++ include_payload_errors(config) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  def validate_config(config) do
    {:error, [%{field: nil, message: "expected a configuration map, got #{inspect(config)}"}]}
  end

  @impl true
  @spec deliver(Request.t() | term(), keyword()) :: Result.t()
  def deliver(%Request{} = request, opts) when is_list(opts) do
    config = normalize_map(request.config)

    with :ok <- validate_config(config),
         envelope = envelope(request, opts),
         :ok <- verify_no_sensitive_values(envelope, declared_sensitive_values(opts)) do
      publish(topic(config), envelope, opts)
    else
      {:error, errors} when is_list(errors) -> invalid_config(errors)
      {:error, :envelope_leak} -> envelope_leak(request)
    end
  rescue
    exception -> unexpected(exception, __STACKTRACE__, request)
  end

  def deliver(request, _opts) do
    Result.permanent_failure("invalid_request",
      error_message: "expected a Transport.Request, got #{inspect(request)}"
    )
  end

  @impl true
  @doc """
  Test publish.

  Deliberately `deliver/2` itself, on the same envelope and the same topic. A
  test that published somewhere else would not be evidence that a subscriber
  receives anything. The delivery carries `is_test: true`, and the envelope says
  so too, so a subscriber can filter test traffic without guessing.
  """
  @spec test(Request.t(), keyword()) :: Result.t()
  def test(request, opts), do: deliver(request, opts)

  @doc "The unscoped firehose topic."
  @spec firehose_topic() :: String.t()
  def firehose_topic, do: @firehose_topic

  @doc """
  The topic a channel publishes to.

  With no configured suffix this is the firehose. An invalid suffix falls back to
  the firehose rather than publishing to an unvalidated topic name;
  `validate_config/1` has already refused to save one, so this path is only
  reachable for a row that predates the check.
  """
  @spec topic(term()) :: String.t()
  def topic(config) when is_map(config) do
    case topic_suffix(normalize_map(config)) do
      nil -> @firehose_topic
      suffix -> @firehose_topic <> ":" <> suffix
    end
  end

  def topic(_config), do: @firehose_topic

  @doc "The envelope schema identifier carried by every published envelope."
  @spec envelope_schema() :: String.t()
  def envelope_schema, do: @envelope_schema

  @doc """
  Builds the canonical envelope for a request, without publishing it.

  The envelope carries the identifiers a subscriber resolves through the
  authenticated API (`alert_id`, `delivery_id`, `channel_id`) and never an action
  link or capability token (design D7). The payload it carries is
  `ActionRedaction`-redacted and action-link-stripped, so what reaches a
  subscriber is the same shape the Delivery Log may display.

  ## Options

    * `:now` - the `DateTime` stamped as `emitted_at`. Defaults to
      `DateTime.utc_now/0`; supply it to keep a test deterministic.
    * `:sensitive_values` - strings that must not appear in the envelope.
  """
  @spec envelope(Request.t(), keyword()) :: map()
  def envelope(%Request{} = request, opts \\ []) do
    config = normalize_map(request.config)
    sensitive = HTTP.sensitive_values(opts)

    %{
      "schema" => @envelope_schema,
      "emitted_at" => emitted_at(opts),
      "delivery_id" => request.delivery_id,
      "alert_id" => request.alert_id,
      "channel_id" => request.channel_id,
      "provider_key" => request.provider_key,
      "provider_version" => request.provider_version,
      "partition_id" => request.partition_id,
      "dedupe_key" => request.dedupe_key,
      "payload_format" => format(request.payload_format),
      "subject" => request.subject,
      "attempt" => request.attempt,
      "is_test" => request.is_test == true,
      "payload" => envelope_payload(request, config, sensitive)
    }
  end

  @doc """
  Removes every acknowledgement action link and capability token from a payload.

  This is the invariant of design D7 that this module owns; see the moduledoc for
  why it is applied even when the renderer was already told to omit them. It
  handles the shapes the first-party renderers emit: a `links` list of
  `%{"action" => ...}` maps (`Renderers.Json`), a `links` map keyed by action,
  and the flat `acknowledge_url` / `snooze_url` / `resolve_url` keys.
  """
  @spec strip_action_links(term()) :: term()
  def strip_action_links(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.reject(fn {key, _child} -> action_link_key?(key) end)
    |> Map.new(fn {key, child} -> {key, strip_action_links(child)} end)
  end

  def strip_action_links(value) when is_list(value) do
    value
    |> Enum.reject(&action_link_entry?/1)
    |> Enum.map(&strip_action_links/1)
  end

  def strip_action_links(value), do: value

  @doc """
  The live-only publish seam: `Phoenix.PubSub` on `ServiceRadar.PubSub`.

  Subscribers receive `{#{inspect(@broadcast_event)}, envelope}`. Override with
  `opts[:broadcast]` in a test. Production delivery uses `default_publish/3`,
  which composes this live fanout after durable JetStream persistence.

  The third argument names the PubSub server and exists so the not-running
  branch below is testable deterministically. Without it a test can only assert
  that branch when `ServiceRadar.PubSub` happens to be down, which makes the
  assertion depend on which test tier is running: green in the database-free
  tier and red under `:requires_app`, where the supervision tree is up.
  """
  @spec default_broadcast(String.t(), map(), atom()) :: :ok | {:error, term()}
  def default_broadcast(topic, envelope, pubsub \\ @default_pubsub) do
    Phoenix.PubSub.broadcast(pubsub, topic, {@broadcast_event, envelope})
  rescue
    # `broadcast/3` raises when the PubSub server is not running - during a
    # partial boot, or in a release where it has crashed. That is a transient
    # condition worth repeating, not a lost notification.
    exception -> {:error, Exception.message(exception)}
  end

  @doc """
  The composed publish seam: durable first, live second.

  Publishes to the JetStream firehose stream and, only once JetStream has
  acknowledged persistence, fans the same envelope out to connected subscribers
  over `Phoenix.PubSub`.

  The order is deliberate and the reverse is the intuitive mistake:

    * **JetStream first.** If it fails, nothing has reached `Phoenix.PubSub`
      yet, so returning an error lets the retry machinery republish without
      live subscribers seeing the envelope twice.
    * **PubSub failure does not fail the delivery.** The envelope is already
      durably recorded at that point. Returning an error would republish it to
      JetStream and duplicate the durable record - and a subscriber that missed
      the live broadcast replays it from its cursor anyway, which is the entire
      reason the durable half exists.

  Override with `opts[:broadcast]` to publish somewhere else, as the tests do.

  The third argument carries the publisher and PubSub seams
  (`:request`, `:connection`, `:pubsub`). It exists so this ordering contract is
  testable without a broker: asserting it only through the arity-2 capture would
  mean asserting it against live NATS, which is exactly the test nobody runs.
  """
  @spec default_publish(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def default_publish(topic, envelope, opts \\ []) do
    case StreamPublisher.publish(topic, envelope, opts) do
      :ok ->
        case default_broadcast(topic, envelope, Keyword.get(opts, :pubsub, @default_pubsub)) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "notification stream persisted but live broadcast failed " <>
                "topic=#{topic} reason=#{inspect(reason)}"
            )

            :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- publishing -----------------------------------------------------------

  defp publish(topic, envelope, opts) do
    broadcast = Keyword.get(opts, :broadcast, &default_publish/2)

    case broadcast.(topic, envelope) do
      :ok -> delivered(topic, envelope)
      {:ok, _reference} -> delivered(topic, envelope)
      {:error, reason} -> publish_failed(topic, reason)
      other -> publish_failed(topic, other)
    end
  end

  defp delivered(topic, envelope) do
    Result.delivered(
      result_summary: %{"topic" => topic, "envelope_schema" => @envelope_schema},
      provider_metadata: %{"payload_format" => envelope["payload_format"]}
    )
  end

  defp publish_failed(topic, reason) do
    Logger.warning("notification stream publish failed topic=#{topic} reason=#{inspect(reason)}")

    Result.retryable_failure("stream_publish_failed",
      error_message: "could not publish to #{topic}: #{inspect(reason)}",
      result_summary: %{"topic" => topic}
    )
  end

  # --- envelope -------------------------------------------------------------

  defp envelope_payload(request, config, sensitive) do
    if include_payload?(config) do
      request.payload
      |> ActionRedaction.redact()
      |> strip_action_links()
      |> HTTP.scrub(sensitive)
    end
  end

  defp include_payload?(config), do: Map.get(config, "include_payload", true) != false

  defp emitted_at(opts) do
    opts
    |> Keyword.get(:now, DateTime.utc_now())
    |> DateTime.to_iso8601()
  end

  defp format(nil), do: nil
  defp format(payload_format) when is_atom(payload_format), do: Atom.to_string(payload_format)
  defp format(payload_format) when is_binary(payload_format), do: payload_format
  defp format(payload_format), do: to_string(payload_format)

  defp action_link_key?(key) when is_binary(key), do: key in @action_link_keys
  defp action_link_key?(key) when is_atom(key), do: Atom.to_string(key) in @action_link_keys
  defp action_link_key?(_key), do: false

  defp action_link_entry?(entry) when is_map(entry) and not is_struct(entry) do
    action = Map.get(entry, "action") || Map.get(entry, :action)

    (is_binary(action) and action in @action_names) or interactive_control?(entry)
  end

  defp action_link_entry?(_entry), do: false

  # An interactive control is as actionable as a signed link and must not reach a
  # broadcast topic either, but it looks nothing like one: a Slack Block Kit
  # button carries `action_id` (NOT `action`) inside
  # `blocks[].elements[]`, and a Discord component carries `custom_id` inside
  # `components[].components[]`. Neither key appears in `@action_link_keys` and
  # neither value is a URL, so a denylist written for Phase 1 links passes both
  # straight through.
  #
  # This is deliberately structural rather than another key-name list. The names
  # that matter are the provider's, not ours, and the failure mode is silent: the
  # envelope looks clean, carries no token, and still hands every subscriber a
  # control that acts on someone else's incident.
  defp interactive_control?(entry) do
    Enum.any?(@interactive_control_keys, &Map.has_key?(entry, &1)) or
      block_of_type?(entry, "actions")
  end

  defp block_of_type?(entry, type) do
    (Map.get(entry, "type") || Map.get(entry, :type)) == type
  end

  # `HTTP.scrub/2` replaces declared sensitive strings in map values, lists, and
  # tuples, but deliberately preserves map keys so redaction cannot change the
  # payload's structure. A caller-controlled key can therefore still carry a
  # declared secret. Check the encoded envelope once more against the caller's
  # unfiltered declarations and fail closed if anything survived.
  defp declared_sensitive_values(opts) do
    opts
    |> Keyword.get(:sensitive_values, [])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp verify_no_sensitive_values(_envelope, []), do: :ok

  defp verify_no_sensitive_values(envelope, sensitive) do
    encoded =
      case Jason.encode(envelope) do
        {:ok, json} -> json
        {:error, _reason} -> inspect(envelope)
      end

    if Enum.any?(sensitive, &String.contains?(encoded, &1)) do
      {:error, :envelope_leak}
    else
      :ok
    end
  end

  # --- configuration --------------------------------------------------------

  defp topic_suffix(config) do
    case Map.get(config, "topic") do
      value when is_binary(value) ->
        trimmed = value |> String.trim() |> String.downcase()
        if Regex.match?(@topic_suffix_regex, trimmed), do: trimmed

      _other ->
        nil
    end
  end

  defp topic_errors(config) do
    case Map.get(config, "topic") do
      nil ->
        []

      value when is_binary(value) ->
        if topic_suffix(config) do
          []
        else
          [
            %{
              field: "topic",
              message:
                "must be lowercase letters, digits, and _ : - (max 64 characters), got #{value}"
            }
          ]
        end

      other ->
        [%{field: "topic", message: "must be a string, got #{inspect(other)}"}]
    end
  end

  defp include_payload_errors(config) do
    case Map.get(config, "include_payload") do
      nil -> []
      value when is_boolean(value) -> []
      other -> [%{field: "include_payload", message: "must be a boolean, got #{inspect(other)}"}]
    end
  end

  # --- failures -------------------------------------------------------------

  defp invalid_config(errors) do
    Result.permanent_failure("invalid_config",
      error_message: describe_errors(errors),
      result_summary: %{"config_errors" => Enum.map(errors, & &1.field)}
    )
  end

  defp describe_errors(errors) do
    Enum.map_join(errors, "; ", fn
      %{field: nil, message: message} -> message
      %{field: field, message: message} -> "#{field} #{message}"
    end)
  end

  defp envelope_leak(request) do
    Logger.error(
      "refusing to publish a notification envelope carrying a sensitive value " <>
        "delivery=#{inspect(request.delivery_id)}"
    )

    Result.permanent_failure("envelope_leak",
      error_message:
        "the envelope still carried a value the caller marked sensitive; nothing was published"
    )
  end

  defp unexpected(exception, stacktrace, request) do
    Logger.error(
      "notification stream transport crashed delivery=#{inspect(delivery_id(request))} " <>
        Exception.format(:error, exception, stacktrace)
    )

    Result.retryable_failure("transport_exception",
      error_message: "the stream transport raised #{inspect(exception.__struct__)}"
    )
  end

  defp delivery_id(%Request{delivery_id: delivery_id}), do: delivery_id
  defp delivery_id(_request), do: nil

  # Atom keys are matched by comparing atoms already present in the map, so no
  # atom is created from operator input (Iron Laws).
  defp normalize_map(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp normalize_map(_map), do: %{}
end
