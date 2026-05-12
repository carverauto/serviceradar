defmodule ServiceRadarWebNGWeb.Plugs.WebhookSignature do
  @moduledoc """
  Verifies an inbound webhook's HMAC-SHA256 signature against the
  matching `ServiceRadar.Security.WebhookSecret` for the configured
  `source_name`.

  On success the plug touches the secret's `last_used_at` timestamp
  and assigns `:webhook_source_name` for downstream controllers. On
  failure it halts with HTTP 401 and lets the caller emit a
  `:signature_invalid` security event (recorded once Section 6 of the
  platform-security-hardening change lands).

  ## Options

    * `:source_name` — string, required. Identifies which row in
      `webhook_secrets` to use.
    * `:signature_header` — request header that carries the signature
      hex. Default `"x-serviceradar-signature"`.
    * `:scheme` — `:hex` (default) or `:base64` for the encoding of
      the signature header value.

  ## Body access

  The plug requires the raw request body to compute the HMAC. Phoenix
  consumes the body during multipart/url-encoded parsing; for webhook
  endpoints that need signature verification the router must configure
  a custom body reader that caches the raw body, or the route must
  bypass `Plug.Parsers` for the `application/json` content type. See
  `Plug.Conn.consume_body/2` and the Phoenix guide on raw body capture.

  This plug looks for the raw body in `conn.assigns[:raw_body]` first,
  falling back to a synchronous `Plug.Conn.consume_body/2` call.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Security.WebhookSecret

  @impl true
  def init(opts) do
    source_name = Keyword.fetch!(opts, :source_name)
    header = Keyword.get(opts, :signature_header, "x-serviceradar-signature")
    scheme = Keyword.get(opts, :scheme, :hex)

    unless scheme in [:hex, :base64] do
      raise ArgumentError,
            "WebhookSignature: :scheme must be :hex or :base64, got #{inspect(scheme)}"
    end

    %{source_name: source_name, header: header, scheme: scheme}
  end

  @impl true
  def call(conn, %{source_name: source_name, header: header, scheme: scheme}) do
    with {:ok, signature} <- read_signature(conn, header),
         {:ok, body, conn} <- consume_request_body(conn),
         {:ok, %WebhookSecret{} = matched} <- find_matching_secret(source_name, body, signature, scheme) do
      _ = touch_async(matched)

      conn
      |> assign(:webhook_source_name, source_name)
      |> assign(:raw_body, body)
    else
      _ -> reject(conn)
    end
  end

  ## Helpers

  defp read_signature(conn, header) do
    case get_req_header(conn, header) do
      [value | _] when byte_size(value) > 0 -> {:ok, value}
      _ -> :error
    end
  end

  defp consume_request_body(conn) do
    case Map.get(conn.assigns, :raw_body) do
      body when is_binary(body) ->
        {:ok, body, conn}

      _ ->
        case Plug.Conn.read_body(conn, length: 8_000_000) do
          {:ok, body, conn} -> {:ok, body, conn}
          _ -> :error
        end
    end
  end

  defp find_matching_secret(source_name, body, signature_value, scheme) do
    actor = SystemActor.system(:webhook_signature)

    case WebhookSecret
         |> Ash.Query.for_read(:verifiable_for_source, %{source_name: source_name})
         |> Ash.read(actor: actor) do
      {:ok, [_ | _] = candidates} ->
        decoded = decode_signature(signature_value, scheme)

        matched =
          Enum.find(candidates, fn %WebhookSecret{secret: secret} when is_binary(secret) ->
            compare_signature(body, secret, decoded)
          end)

        case matched do
          nil -> :error
          %WebhookSecret{} = secret -> {:ok, secret}
        end

      _ ->
        :error
    end
  end

  defp decode_signature(value, :hex) do
    case Base.decode16(String.downcase(value)) do
      {:ok, binary} -> binary
      _ -> :error
    end
  end

  defp decode_signature(value, :base64) do
    case Base.decode64(value) do
      {:ok, binary} -> binary
      _ -> :error
    end
  end

  defp compare_signature(_body, _secret, :error), do: false

  defp compare_signature(body, secret, signature) when is_binary(signature) do
    expected = :crypto.mac(:hmac, :sha256, secret, body)
    Plug.Crypto.secure_compare(expected, signature)
  end

  defp touch_async(%WebhookSecret{} = secret) do
    Task.Supervisor.start_child(
      Task.Supervisor,
      fn ->
        actor = SystemActor.system(:webhook_signature)

        try do
          WebhookSecret.touch_last_used(secret, actor: actor)
        rescue
          e -> Logger.debug("WebhookSignature: touch failed: #{inspect(e)}")
        end
      end
    )
  rescue
    # If Task.Supervisor isn't configured, fail silently — last_used_at
    # is best-effort and must not break verification.
    _ -> :ok
  end

  defp reject(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, ~s({"error":"invalid_webhook_signature"}))
    |> halt()
  end
end
