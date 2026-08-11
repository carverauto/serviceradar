defmodule ServiceRadar.Notifications.Callbacks.Slack do
  @moduledoc """
  Verifies a Slack interactivity POST (tasks 4.3.1, 4.3.4).

  Slack signs `"v0:" <> timestamp <> ":" <> raw_body` with the **app's signing
  secret** and sends the lower-case hex digest as `x-slack-signature`, prefixed
  `v0=`, alongside `x-slack-request-timestamp`.

  Three details are where implementations go wrong, and each is guarded here:

    * **The separators are colons, not a period.** Northbound signs
      `"<timestamp>.<raw_body>"`. Reusing that builder here produces a digest
      that never matches, and the symptom is an authentication failure that looks
      exactly like a wrong secret.
    * **The bytes must be the ones Slack sent.** Slack posts
      `application/x-www-form-urlencoded` with the interaction JSON inside a
      `payload` parameter. Re-encoding Plug's parsed params changes parameter
      order and percent-encoding, so the HMAC is computed over the raw buffered
      body or not at all - hence `require_raw_body/2` rather than a defaulted
      `""`.
    * **The version prefix is parsed, not stripped.** Slack documents `v0` and
      does not promise it is the last version. An unrecognised prefix is
      `:unsupported_signature_version`; assuming v0 and slicing three characters
      off a future `v1=` signature would compare a truncated digest and fail
      confusingly, or worse, compare successfully against an attacker-chosen
      scheme.

  Not used for authorisation: the `token` field inside the interaction body is
  Slack's deprecated verification token. The signature is the authorisation.
  """

  @behaviour ServiceRadar.Notifications.Callbacks.Signature

  alias ServiceRadar.Notifications.Callbacks.Primitives

  @signature_header "x-slack-signature"
  @timestamp_header "x-slack-request-timestamp"

  @signature_version "v0"
  @signature_prefix @signature_version <> "="

  # Slack's documented replay window.
  @tolerance_seconds 300

  @impl true
  def provider_key, do: :slack

  @impl true
  @doc """
  Reads the interaction Slack posted.

  Slack sends `application/x-www-form-urlencoded` with the whole interaction as
  a JSON string in a single `payload` parameter, so this is two decodes: Plug's
  form parse, then `Jason`. The raw body is accepted as a fallback for a caller
  that has not run the form parser.

  Only `block_actions` is handled. Anything else - a view submission, a shortcut -
  is refused rather than half-interpreted, because a payload whose shape we did
  not anticipate is not one to guess an alert id out of.
  """
  @spec decode_interaction(map()) :: {:ok, map()} | {:error, atom()}
  def decode_interaction(%{} = request) do
    with {:ok, json} <-
           payload_json(Map.get(request, :params) || %{}, Map.get(request, :raw_body) || ""),
         {:ok, decoded} <- decode_json(json),
         :ok <- check_type(decoded),
         {:ok, app_id} <- non_empty(decoded, "api_app_id", :missing_app_id),
         {:ok, action} <- first_action(decoded) do
      {:ok,
       %{
         app_id: app_id,
         user_id: get_in(decoded, ["user", "id"]),
         team_id: get_in(decoded, ["team", "id"]),
         action_id: Map.get(action, "action_id"),
         value: Map.get(action, "value")
       }}
    end
  end

  @impl true
  @doc """
  Turns a decoded interaction into the capability the redemption path accepts.

  The button's `value` is the string `SlackBlocks.control_value/1` wrote, parsed
  here rather than re-derived: the two must agree, and the way they stop agreeing
  is one of them being rewritten from memory.

  `external_principal` is `"slack:<user id>"` - the Slack user is not a platform
  user, so the acknowledgement is attributed to an external principal, which is
  what `actor_kind: :external_principal` records.
  """
  @spec capability(map()) :: {:ok, map()} | {:error, atom()}
  def capability(%{value: value} = interaction) when is_binary(value) do
    case String.split(value, ":") do
      [action, alert_id, delivery_id | rest] ->
        with {:ok, action} <- known_action(action) do
          {:ok,
           %{
             action: action,
             alert_id: alert_id,
             delivery_id: delivery_id,
             snooze_seconds: snooze_seconds(rest),
             external_principal: principal(interaction),
             app_id: Map.get(interaction, :app_id),
             action_id: Map.get(interaction, :action_id)
           }}
        end

      _other ->
        {:error, :unparseable_control_value}
    end
  end

  def capability(_interaction), do: {:error, :missing_control_value}

  defp payload_json(params, raw_body) do
    case Map.get(params || %{}, "payload") do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _absent ->
        # A caller that has not run Plug's form parser, e.g. a test posting raw
        # bytes. Decoding the form here keeps the verifier usable either way.
        case URI.decode_query(raw_body || "") do
          %{"payload" => value} when is_binary(value) and value != "" -> {:ok, value}
          _other -> {:error, :missing_payload}
        end
    end
  end

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _other -> {:error, :invalid_payload}
    end
  end

  defp check_type(%{"type" => "block_actions"}), do: :ok
  defp check_type(_decoded), do: {:error, :unsupported_interaction_type}

  defp non_empty(decoded, key, error) do
    case Map.get(decoded, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _absent -> {:error, error}
    end
  end

  defp first_action(%{"actions" => [action | _rest]}) when is_map(action), do: {:ok, action}
  defp first_action(_decoded), do: {:error, :missing_action}

  defp known_action("acknowledge"), do: {:ok, :acknowledge}
  defp known_action("snooze"), do: {:ok, :snooze}
  defp known_action("resolve"), do: {:ok, :resolve}
  defp known_action(_other), do: {:error, :unknown_action}

  defp snooze_seconds([seconds | _rest]) when is_binary(seconds) do
    case Integer.parse(seconds) do
      {value, ""} when value > 0 -> value
      _other -> nil
    end
  end

  defp snooze_seconds(_rest), do: nil

  defp principal(%{user_id: user_id}) when is_binary(user_id) and user_id != "",
    do: "slack:" <> user_id

  defp principal(_interaction), do: "slack"

  @doc "The headers this verifier reads, for route and fixture assertions."
  @spec headers() :: %{signature: String.t(), timestamp: String.t()}
  def headers, do: %{signature: @signature_header, timestamp: @timestamp_header}

  @doc "The replay tolerance, in seconds."
  @spec tolerance_seconds() :: pos_integer()
  def tolerance_seconds, do: @tolerance_seconds

  @doc """
  The exact string Slack signs. Public so a test signs what Slack would sign
  rather than restating the format and testing its own restatement.
  """
  @spec base_string(String.t(), binary()) :: binary()
  def base_string(timestamp, raw_body) when is_binary(timestamp) and is_binary(raw_body) do
    @signature_version <> ":" <> timestamp <> ":" <> raw_body
  end

  @doc """
  Signs a body as Slack would. Used by tests and by the channel `test` action.
  """
  @spec sign(String.t(), binary(), String.t()) :: String.t()
  def sign(timestamp, raw_body, signing_secret) do
    @signature_prefix <>
      Primitives.hmac_sha256_hex(signing_secret, base_string(timestamp, raw_body))
  end

  @impl true
  @spec verify(binary(), Primitives.headers(), String.t(), keyword()) ::
          :ok | {:error, atom()}
  def verify(raw_body, headers, signing_secret, opts \\ [])

  def verify(raw_body, headers, signing_secret, opts)
      when is_binary(signing_secret) and signing_secret != "" do
    with {:ok, body} <-
           Primitives.require_raw_body(raw_body, Keyword.get(opts, :content_length)),
         {:ok, presented} <- presented_signature(headers),
         {:ok, timestamp_string} <- timestamp_string(headers),
         {:ok, timestamp} <- Primitives.parse_unix_timestamp(timestamp_string),
         :ok <- check_tolerance(timestamp, opts) do
      expected = Primitives.hmac_sha256_hex(signing_secret, base_string(timestamp_string, body))

      if Primitives.hex_equal?(presented, expected) do
        :ok
      else
        {:error, :invalid_signature}
      end
    end
  end

  def verify(_raw_body, _headers, _signing_secret, _opts), do: {:error, :missing_key_material}

  defp presented_signature(headers) do
    case Primitives.header(headers, @signature_header) do
      value when is_binary(value) and value != "" -> strip_version(String.trim(value))
      _absent -> {:error, :missing_signature}
    end
  end

  defp strip_version(value) do
    if String.starts_with?(String.downcase(value), @signature_prefix) do
      {:ok,
       binary_part(
         value,
         byte_size(@signature_prefix),
         byte_size(value) - byte_size(@signature_prefix)
       )}
    else
      {:error, :unsupported_signature_version}
    end
  end

  defp timestamp_string(headers) do
    case Primitives.header(headers, @timestamp_header) do
      value when is_binary(value) and value != "" -> {:ok, String.trim(value)}
      _absent -> {:error, :missing_timestamp}
    end
  end

  defp check_tolerance(timestamp, opts) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    tolerance = Keyword.get(opts, :tolerance_seconds, @tolerance_seconds)

    if Primitives.within_tolerance?(timestamp, now, tolerance) do
      :ok
    else
      {:error, :stale_timestamp}
    end
  end
end
