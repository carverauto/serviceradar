defmodule ServiceRadarWebNGWeb.Auth.NarrowScopes do
  @moduledoc """
  The authoritative answer to "what may a narrow-scoped bearer token reach".

  Two unrelated scope vocabularies flow through `Plugs.ApiAuth`:

    * **Coarse** scopes minted for OAuth2 client-credential integrations --
      `read`, `write`, `admin`, `mcp` (`ServiceRadar.Identity.OAuthClient`
      `:scopes`). These describe a breadth of access, not a single operation,
      and every machine integration holds one.

    * **Narrow** scopes minted for the RFC 8628 CLI device flow --
      `dashboard.publish`, `plugin.publish`, `plugins.manage`
      (`AuthorizationSettings` `:cli_allowed_scopes`). Each names one CLI
      operation a developer approved in a browser.

  `ApiAuth` records the granted scope string on `:oauth_token_scope` but does
  not enforce it; enforcement lived only on the two routes that mounted
  `Plugs.RequireOauthScope`. A narrow token was therefore accepted anywhere in
  `/api/v1` that its user's RBAC permitted -- a `dashboard.publish` token could
  stage a plugin package, because staging checks `plugins.stage` on the user and
  never looks at what the token was actually granted for.

  This module closes that by inverting the default: a token holding *only*
  narrow scopes may reach only the routes listed here, and nothing else. New
  routes are unreachable to narrow tokens until someone adds them, which is the
  failure direction we want -- a forgotten entry denies a CLI, it does not
  silently widen a token.

  Coarse-scoped and unscoped callers (API keys, browser sessions, legacy static
  keys) are deliberately untouched: `allowed?/3` passes them through so this
  cannot regress an existing integration. Tightening `read` so it cannot POST is
  a separate, breaking decision that needs its own audit of live clients.
  """

  @coarse_scopes ~w(read write admin mcp)

  # scope => [{method, path matcher}]. Path matchers are compiled regexes so a
  # UUID segment cannot be used to reach a sibling route. Keep these anchored.
  @routes %{
    "dashboard.publish" => [
      {"POST", ~r{^/api/v1/dashboard-packages$}},
      {"POST", ~r{^/api/v1/dashboard-packages/[^/]+/enable$}},
      {"POST", ~r{^/api/v1/dashboard-packages/[^/]+/disable$}}
    ],
    # The bundle upload itself (`PUT /api/plugin-packages/:id/blob`) is absent on
    # purpose: it runs on the `:api` pipeline and is gated by the short-TTL
    # storage token minted by `upload-url`, never by a user bearer token, so it
    # never reaches this plug.
    "plugin.publish" => [
      {"GET", ~r{^/api/admin/plugin-packages/[^/]+$}},
      {"POST", ~r{^/api/admin/plugin-packages$}},
      {"POST", ~r{^/api/admin/plugin-packages/[^/]+/upload-url$}}
    ],
    "plugins.manage" => [
      {"GET", ~r{^/api/admin/plugins$}},
      {"GET", ~r{^/api/admin/plugins/[^/]+$}},
      {"GET", ~r{^/api/admin/plugin-packages$}},
      {"GET", ~r{^/api/admin/plugin-packages/[^/]+$}},
      {"GET", ~r{^/api/admin/plugin-assignments$}},
      {"POST", ~r{^/api/admin/plugin-assignments$}},
      {"GET", ~r{^/api/admin/plugin-assignments/[^/]+$}},
      {"PATCH", ~r{^/api/admin/plugin-assignments/[^/]+$}},
      {"DELETE", ~r{^/api/admin/plugin-assignments/[^/]+$}},
      {"GET", ~r{^/api/admin/network-credential-secrets$}},
      {"POST", ~r{^/api/admin/network-credential-secrets$}},
      {"GET", ~r{^/api/admin/network-credential-secrets/[^/]+$}},
      {"PATCH", ~r{^/api/admin/network-credential-secrets/[^/]+$}},
      {"POST", ~r{^/api/admin/network-credential-secrets/[^/]+/rotate$}},
      {"GET", ~r{^/api/admin/network-credential-rules$}},
      {"POST", ~r{^/api/admin/network-credential-rules$}},
      {"GET", ~r{^/api/admin/network-credential-rules/[^/]+$}},
      {"PATCH", ~r{^/api/admin/network-credential-rules/[^/]+$}},
      {"POST", ~r{^/api/admin/network-credential-rules/[^/]+/enable$}},
      {"POST", ~r{^/api/admin/network-credential-rules/[^/]+/disable$}},
      {"GET", ~r{^/api/admin/ansible-controllers$}},
      {"POST", ~r{^/api/admin/ansible-controllers$}},
      {"GET", ~r{^/api/admin/ansible-controllers/[^/]+$}},
      {"PATCH", ~r{^/api/admin/ansible-controllers/[^/]+$}},
      {"POST", ~r{^/api/admin/ansible-controllers/[^/]+/enable$}},
      {"POST", ~r{^/api/admin/ansible-controllers/[^/]+/disable$}}
    ]
  }

  @doc "Every narrow scope this deployment knows how to enforce."
  @spec known() :: [String.t()]
  def known, do: Map.keys(@routes)

  @doc "The coarse client-credential scopes, which this module does not constrain."
  @spec coarse() :: [String.t()]
  def coarse, do: @coarse_scopes

  @doc """
  Routes reachable by `scope`, as `{method, regex}` pairs. Used by tests to
  assert that the routes mounting `RequireOauthScope` and the entries here have
  not drifted apart.
  """
  @spec routes(String.t()) :: [{String.t(), Regex.t()}]
  def routes(scope) when is_binary(scope), do: Map.get(@routes, scope, [])

  @doc """
  True when a token granted `scopes` may reach `method` `path`.

  Passes through anything that is not a narrow-only token: an empty scope set
  (API key, session, or a token with no scopes claim) and any set holding a
  coarse scope. Narrow-only sets must match an allowlisted route.
  """
  @spec allowed?([String.t()], String.t(), String.t()) :: boolean()
  def allowed?(scopes, method, path) when is_list(scopes) and is_binary(method) and is_binary(path) do
    cond do
      scopes == [] -> true
      Enum.any?(scopes, &(&1 in @coarse_scopes)) -> true
      true -> Enum.any?(scopes, &scope_allows?(&1, method, path))
    end
  end

  def allowed?(_scopes, _method, _path), do: false

  @doc "Splits a space-separated scope claim into a list."
  @spec parse(String.t() | nil) :: [String.t()]
  def parse(nil), do: []

  def parse(value) when is_binary(value), do: String.split(value, ~r/\s+/, trim: true)

  def parse(_value), do: []

  defp scope_allows?(scope, method, path) do
    scope
    |> routes()
    |> Enum.any?(fn {allowed_method, matcher} ->
      allowed_method == method and Regex.match?(matcher, path)
    end)
  end
end
