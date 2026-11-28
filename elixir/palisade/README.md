# Palisade

Palisade checks the trust boundary of an Elixir web service.

Outbound helpers accept an HTTPS URL only when the host resolves to a public address, then send the request to that address. TLS verification and the `Host` header stay on the original hostname. Plug modules cover the HTTP edge: security headers, the client address, rate limits, caps on long-lived connections, and rejection of malformed requests.

Apache-2.0. Elixir `~> 1.15`. Fetches use [Req](https://hex.pm/packages/req). The edge modules use [Plug](https://hex.pm/packages/plug).

[![Hex.pm](https://img.shields.io/hexpm/v/palisade.svg)](https://hex.pm/packages/palisade)

## Installation

```elixir
def deps do
  [
    {:palisade, "~> 0.2"}
  ]
end
```

Palisade has no application callback. Start the rate-limit table and the connection limiter from your supervision tree when you use them:

```elixir
children = [
  {Palisade.RateLimit.ETS, max_entries: 100_000},
  {Palisade.ConnectionLimiter, name: MyAppWeb.LiveLimiter, max_active_per_key: 20},
  MyAppWeb.Endpoint
]
```

Each function and plug takes its settings as options. The module docs list every option and its default.

## Outbound requests

`Palisade.NetworkAddressPolicy` rejects loopback, link-local, private, and other special-use addresses, plus `localhost` and `*.local`. A DNS answer that includes any rejected address rejects the host. `ip_in_any_cidr?/2` and `cidr_contains?/2` match an address against CIDRs you supply. An IPv4-mapped IPv6 address matches the IPv4 range of the address it embeds.

`Palisade.OutboundURLPolicy` accepts `https` URLs whose port is allow-listed (`443` by default) and whose host passes `NetworkAddressPolicy`.

```elixir
Palisade.OutboundURLPolicy.validate_https_public_url(
  "https://accounts.example.com/.well-known/openid-configuration"
)
# {:ok, %URI{}}
```

`Palisade.OutboundFetch` performs the request against the address that policy approved. Redirects are off. The connect timeout is 5 seconds and the receive timeout is 10 seconds. A GET or HEAD retries once when a pooled connection is already closed. Pass `resolved_address:` when you already resolved the host, and `retry:` to replace the retry policy for one call.

```elixir
Palisade.OutboundFetch.get(
  "https://accounts.example.com/.well-known/openid-configuration"
)
# {:ok, %Req.Response{}} | {:error, _}
```

## Web edge

Put `RemoteIP` and `RequestGuard` in the endpoint, ahead of `Plug.Parsers` and the router. Put `RateLimit` on the pipelines that need their own bucket.

```elixir
# lib/my_app_web/endpoint.ex
@client_ip [trusted_proxies: ["10.0.0.0/8"]]

plug Palisade.Plug.RemoteIP, @client_ip
plug Palisade.Plug.RequestGuard, max_query_length: 4_096
plug Palisade.Plug.SecurityHeaders, csp_report_uri: "/csp-report"
```

```elixir
# lib/my_app_web/router.ex
pipeline :login do
  plug Palisade.Plug.RateLimit, bucket: :login, limit: 5, window_ms: 60_000
end
```

`Palisade.Plug.SecurityHeaders` sets a content security policy, HSTS on HTTPS responses, `Permissions-Policy`, `Referrer-Policy`, `X-Content-Type-Options`, and `X-Frame-Options`. The default policy allows scripts, styles, images, fonts, connections, and the manifest from the same origin, and allows nothing else. Pass `:content_security_policy` to replace it. `:csp_mode` set to `:report_only` sends the report-only header. Values are fixed when the plug starts. A later plug can replace a header on one response.

`Palisade.ClientIP` returns the socket peer. It reads `X-Forwarded-For` only when that peer sits inside `:trusted_proxies`. The default is `[]`, so the header is ignored until you name your proxies. The walk starts at the nearest proxy and stops at the first address outside those CIDRs. An oversized or malformed chain returns the peer. `Palisade.Plug.RemoteIP` writes the result to `conn.remote_ip` and keeps the socket peer in `conn.private[:palisade_peer_ip]`. `ClientIP.from_connect_info/2` gives a LiveView socket the same answer.

`Palisade.Plug.RateLimit` counts `{bucket, client}` through a `Palisade.RateLimit` backend. The backend in the package is `Palisade.RateLimit.ETS`, one bounded table on a single node. A full table denies keys it does not already track. Allowed responses carry `x-ratelimit-limit`, `x-ratelimit-remaining`, and `x-ratelimit-reset`. A denied request stops with status 429 and `retry-after`. Another backend implements `Palisade.RateLimit` and is selected with `backend: {MyBackend, opts}`.

`Palisade.ConnectionLimiter` admits a long-lived connection against caps on how many are active and how fast new ones arrive, both overall and per key. The owner process holds the slot until it exits. Admit a LiveView on the connected mount:

```elixir
def mount(_params, _session, socket) do
  if connected?(socket) do
    ip = Palisade.ClientIP.from_connect_info(socket.private.connect_info, @client_ip)

    case Palisade.ConnectionLimiter.admit(MyAppWeb.LiveLimiter, ip) do
      :ok -> {:ok, socket}
      {:error, _reason} -> {:ok, redirect(socket, to: "/busy")}
    end
  else
    {:ok, socket}
  end
end
```

`Palisade.Plug.RequestGuard` rejects a GET or HEAD that carries a body or `transfer-encoding` (400), a query string longer than `:max_query_length` (414, default 4096 bytes), more headers than `:max_headers` (431, default 100), and, when `:allowed_query_params` is set, a query parameter outside that list (400).
