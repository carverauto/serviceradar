defmodule ServiceRadarWebNGWeb.Plugs.SecurityHeaders do
  @moduledoc """
  Adds defense-in-depth response headers on top of Phoenix's defaults.

  Phoenix's `put_secure_browser_headers/2` already sets
  `x-frame-options`, `x-content-type-options`, `referrer-policy`,
  `x-permitted-cross-domain-policies`, and friends. This plug fills
  the gaps:

    * `strict-transport-security` (HSTS) on HTTPS responses.
    * `permissions-policy` denying camera / microphone / geolocation /
      payment / USB / serial / fullscreen-without-gesture by default.
    * CSP report-only toggle and `report-uri` injection so the existing
      CSP can roll out enforcement gradually without redeploys.

  ## Options

    * `:hsts_max_age` — `max-age` value for HSTS in seconds.
      Default 63_072_000 (two years).
    * `:hsts_include_subdomains` — append `; includeSubDomains`.
      Default `true`.
    * `:hsts_preload` — append `; preload`. Default `false`. Only set
      once the domain is actually enrolled in the HSTS preload list.
    * `:permissions_policy` — full Permissions-Policy header value.
      Default denies `camera`, `microphone`, `geolocation`, `payment`,
      `usb`, `serial`, `fullscreen`.
    * `:csp_mode` — `:enforce` (default) or `:report_only`. When
      `:report_only`, any `content-security-policy` header already set
      on the response is rewritten as `content-security-policy-report-only`.
    * `:csp_report_uri` — when set, appended to the CSP body as
      `; report-uri=<uri>`. Default `nil`.

  Runtime configuration overrides every option:

      config :serviceradar_web_ng, ServiceRadarWebNGWeb.Plugs.SecurityHeaders,
        csp_mode: :report_only,
        csp_report_uri: "/api/security/csp-report",
        hsts_preload: true

  Place this plug in any pipeline that needs the extra headers — it is
  safe to run on both HTML and JSON responses.
  """

  @behaviour Plug

  import Plug.Conn

  alias Palisade.Plug.SecurityHeaders, as: PalisadeHeaders

  @default_permissions_policy "camera=(), microphone=(), geolocation=(), payment=(), usb=(), serial=(), fullscreen=(self), display-capture=()"
  @default_hsts_max_age 63_072_000

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    runtime = Application.get_env(:serviceradar_web_ng, __MODULE__, [])
    opts = Keyword.merge(opts, runtime)
    headers = palisade_headers(opts)

    register_before_send(conn, &apply_headers(&1, opts, headers))
  end

  # Websocket upgrades (`WebSockAdapter.upgrade/4`, e.g. the camera relay
  # browser stream) run before_send callbacks with the conn already handed to
  # the transport (`state: :upgraded`). Response headers can no longer be
  # written at that point — `put_resp_header/3` raises
  # `Plug.Conn.AlreadySentError`, turning every websocket upgrade in a
  # pipeline with this plug into a 500. Skip: an upgraded (or already-sent)
  # response has no browser document left to protect.
  defp apply_headers(%Plug.Conn{state: state} = conn, _opts, _headers) when state in [:sent, :upgraded] do
    conn
  end

  defp apply_headers(conn, opts, headers) do
    conn
    |> PalisadeHeaders.call(headers)
    |> apply_csp_mode(opts)
  end

  # HSTS and Permissions-Policy come from palisade. CSP stays here: the router
  # already set a product policy (map tiles, and so on) and this plug only
  # appends `report-uri` or moves that policy to report-only. Palisade's own
  # referrer, content-type and frame headers are left off so Phoenix's
  # `put_secure_browser_headers/2` remains the source for those.
  defp palisade_headers(opts) do
    PalisadeHeaders.init(
      content_security_policy: false,
      referrer_policy: false,
      content_type_options: false,
      frame_options: false,
      hsts: :https,
      hsts_max_age: Keyword.get(opts, :hsts_max_age, @default_hsts_max_age),
      hsts_include_subdomains: Keyword.get(opts, :hsts_include_subdomains, true),
      hsts_preload: Keyword.get(opts, :hsts_preload, false),
      permissions_policy: Keyword.get(opts, :permissions_policy, @default_permissions_policy)
    )
  end

  defp apply_csp_mode(conn, opts) do
    mode = Keyword.get(opts, :csp_mode, :enforce)
    report_uri = Keyword.get(opts, :csp_report_uri)

    case get_resp_header(conn, "content-security-policy") do
      [csp | _] ->
        csp = append_report_uri(csp, report_uri)

        case mode do
          :enforce ->
            put_resp_header(conn, "content-security-policy", csp)

          :report_only ->
            conn
            |> delete_resp_header("content-security-policy")
            |> put_resp_header("content-security-policy-report-only", csp)
        end

      [] ->
        conn
    end
  end

  defp append_report_uri(csp, nil), do: csp

  defp append_report_uri(csp, uri) when is_binary(uri) do
    if String.contains?(csp, "report-uri") do
      csp
    else
      String.trim_trailing(csp, ";") <> "; report-uri " <> uri
    end
  end
end
