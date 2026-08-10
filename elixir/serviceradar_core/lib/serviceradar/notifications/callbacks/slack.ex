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
  def provider_key, do: "slack"

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
