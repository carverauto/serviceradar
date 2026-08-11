defmodule ServiceRadarWebNGWeb.Api.NotificationCallbackController do
  @moduledoc """
  The inbound endpoint a provider's interactive component posts to
  (tasks 4.3.0b, 4.3.0c, 4.3.4).

  One route per provider, dispatched through a closed map. The provider segment
  is operator-visible URL text, so it never reaches `String.to_atom/1`; an
  unknown segment is a 404 before anything else happens.

  ## The shape, and why it is this shape

  Verify, enqueue, answer. Every provider imposes a response deadline (Slack's
  is 3 seconds) and applying the acknowledgement opens a database transaction, so
  the work happens in `ServiceRadar.Notifications.CallbackWorker` and this
  answers immediately. An operator whose click succeeded must not see an error
  because the database was busy.

  ## Reading the body before verifying it

  The app id that selects the signing secret is *inside* the request, so the body
  is parsed before the signature is checked. That is unavoidable for a
  multi-app deployment and it is safe because of what happens in between:
  nothing. The parse extracts an identifier and performs a lookup; no state
  changes and nothing is enqueued until `verify/4` has returned `:ok` over the
  **raw** bytes - not the re-encoded parse, which would not match.

  ## One answer for every refusal

  Every failure answers `401` with no body. An unauthenticated caller learns
  nothing about whether an app is registered, whether a delivery exists, or which
  of the two failed - each of which is a membership oracle. The distinction is
  logged, because an operator debugging a silent Slack button needs to know
  whether the app was never registered or the secret is wrong.

  The single exception is a raw body that was not buffered. That is a deployment
  fault - a route whose prefix is missing from
  `ServiceRadarWebNGWeb.Api.RawBodyReader` - and it is logged at error, because
  reporting it as an ordinary bad signature is how someone spends a day rotating
  a perfectly good secret.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Notifications.Callbacks
  alias ServiceRadar.Notifications.CallbackWorker
  alias ServiceRadarWebNGWeb.Api.RawBodyReader

  require Logger

  # Closed dispatch. Discord is deliberately absent: see design.md D7 for why it
  # is not feasible on the current credential model.
  @providers %{"slack" => Callbacks.Slack, "pagerduty" => Callbacks.PagerDuty}

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"provider" => provider} = params) do
    case Map.fetch(@providers, provider) do
      {:ok, verifier} -> handle(conn, verifier, params)
      :error -> send_resp(conn, 404, "")
    end
  end

  def create(conn, _params), do: send_resp(conn, 404, "")

  defp handle(conn, verifier, params) do
    raw_body = RawBodyReader.raw_body(conn)

    with {:ok, interaction} <- decode(verifier, conn, params, raw_body),
         {:ok, secret} <- key_material(verifier, interaction),
         :ok <- verify(conn, verifier, raw_body, secret),
         {:ok, capability} <- capability(verifier, interaction) do
      enqueue(conn, verifier, capability)
    else
      {:error, reason} -> refuse(conn, verifier, reason)
    end
  end

  defp decode(verifier, conn, params, raw_body) do
    verifier.decode_interaction(%{
      params: params,
      headers: conn.req_headers,
      raw_body: raw_body
    })
  end

  defp key_material(verifier, interaction) do
    Callbacks.AppRegistry.signing_secret(verifier.provider_key(), interaction.app_id)
  end

  defp verify(conn, verifier, raw_body, secret) do
    verifier.verify(raw_body, conn.req_headers, secret, content_length: content_length(conn))
  end

  defp capability(verifier, interaction), do: verifier.capability(interaction)

  defp enqueue(conn, verifier, capability) do
    capability
    |> Map.put(:provider_key, verifier.provider_key())
    |> CallbackWorker.build()
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        # An empty 200 is the minimal acknowledgement every provider accepts. A
        # visible response, where a provider supports one, is the worker's job -
        # it is the only party that knows what actually happened.
        send_resp(conn, 200, "")

      {:error, reason} ->
        # The signature was good and the click was real, so this is our fault.
        # 500 lets a provider that retries do so; 200 would silently drop a
        # verified acknowledgement.
        Logger.error("notification callback could not be enqueued reason=#{inspect(reason)}")
        send_resp(conn, 500, "")
    end
  end

  defp refuse(conn, verifier, :raw_body_unavailable) do
    Logger.error(
      "notification callback raw body was not buffered provider=#{verifier.provider_key()} " <>
        "path=#{conn.request_path} - register the prefix with RawBodyReader"
    )

    send_resp(conn, 401, "")
  end

  defp refuse(conn, verifier, reason) do
    Logger.warning(
      "notification callback refused provider=#{verifier.provider_key()} " <>
        "reason=#{inspect(reason)}"
    )

    send_resp(conn, 401, "")
  end

  defp content_length(conn) do
    case Plug.Conn.get_req_header(conn, "content-length") do
      [value | _rest] ->
        case Integer.parse(value) do
          {length, _rest} -> length
          :error -> nil
        end

      [] ->
        nil
    end
  end
end
