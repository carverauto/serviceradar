defmodule Palisade.Plug.SecurityHeaders do
  @moduledoc """
  Sets browser security headers from explicit options.

  Every value is fixed when the plug is initialized; nothing is read from
  application environment at request time. The headers are written when the
  plug runs, so a later plug or controller can still replace one for a
  specific response.

  ## Headers

    * `content-security-policy`, or `content-security-policy-report-only` in
      report-only mode. Exactly one of the two is present.
    * `strict-transport-security`, on HTTPS requests (or always, when forced).
    * `permissions-policy`
    * `referrer-policy`
    * `x-content-type-options`
    * `x-frame-options`

  ## Options

    * `:content_security_policy` - the policy. A keyword list of directives,
      a prebuilt string, or `false` to send no policy. Directive names are
      atoms with underscores (`:script_src` becomes `script-src`). A value is
      a list of sources, a single source string, or `true` for a directive
      without sources (`upgrade_insecure_requests: true`). Defaults to
      `default_content_security_policy/0`.
    * `:csp_mode` - `:enforce` (default) or `:report_only`.
    * `:csp_report_uri` - appended to the policy as `report-uri <uri>` when
      the policy does not already name one. Default `nil`.
    * `:hsts` - `:https` (default) sends HSTS only when `conn.scheme` is
      `:https`, `:always` sends it on every response (for TLS terminated at a
      proxy), `false` never sends it.
    * `:hsts_max_age` - seconds. Default `63_072_000` (two years).
    * `:hsts_include_subdomains` - default `true`.
    * `:hsts_preload` - default `false`. Enable only once the domain is
      enrolled in the HSTS preload list.
    * `:permissions_policy` - header value, or `false`. The default denies
      camera, microphone, geolocation, payment, USB, serial and display
      capture, and allows fullscreen for the same origin.
    * `:referrer_policy` - default `"strict-origin-when-cross-origin"`, or
      `false`.
    * `:content_type_options` - default `"nosniff"`, or `false`.
    * `:frame_options` - default `"DENY"`, or `false`.

  Option values are checked when the plug is initialized. A value containing a
  control character, or a CSP source containing `;` or `,`, raises
  `ArgumentError` rather than reaching a response header.

  ## Example

      plug Palisade.Plug.SecurityHeaders,
        content_security_policy:
          Keyword.merge(Palisade.Plug.SecurityHeaders.default_content_security_policy(),
            img_src: ["'self'", "data:"]
          ),
        csp_mode: :report_only,
        csp_report_uri: "/csp-report"
  """

  @behaviour Plug

  import Plug.Conn

  @default_csp [
    default_src: ["'none'"],
    script_src: ["'self'"],
    style_src: ["'self'"],
    img_src: ["'self'"],
    font_src: ["'self'"],
    connect_src: ["'self'"],
    manifest_src: ["'self'"],
    base_uri: ["'self'"],
    form_action: ["'self'"],
    frame_ancestors: ["'none'"]
  ]

  @default_permissions_policy "camera=(), microphone=(), geolocation=(), payment=(), usb=(), " <>
                                "serial=(), display-capture=(), fullscreen=(self)"

  @defaults [
    content_security_policy: @default_csp,
    csp_mode: :enforce,
    csp_report_uri: nil,
    hsts: :https,
    hsts_max_age: 63_072_000,
    hsts_include_subdomains: true,
    hsts_preload: false,
    permissions_policy: @default_permissions_policy,
    referrer_policy: "strict-origin-when-cross-origin",
    content_type_options: "nosniff",
    frame_options: "DENY"
  ]

  @csp_header "content-security-policy"
  @csp_report_only_header "content-security-policy-report-only"

  @doc """
  The default policy: nothing is allowed unless named, scripts, styles,
  images, fonts, connections and the manifest load from the same origin only,
  forms post and `<base>` points only to the same origin, and no page may
  frame this one.
  """
  @spec default_content_security_policy() :: keyword()
  def default_content_security_policy, do: @default_csp

  @impl Plug
  def init(opts) when is_list(opts) do
    opts = Keyword.merge(@defaults, opts)

    %{
      headers: static_headers(opts),
      csp: csp_header(opts),
      hsts: hsts_header(opts)
    }
  end

  @impl Plug
  def call(conn, %{headers: headers, csp: csp, hsts: hsts}) do
    conn
    |> merge_resp_headers(headers)
    |> put_csp(csp)
    |> put_hsts(hsts)
  end

  defp put_csp(conn, nil), do: conn

  defp put_csp(conn, {name, value}) do
    other = if name == @csp_header, do: @csp_report_only_header, else: @csp_header

    conn
    |> delete_resp_header(other)
    |> put_resp_header(name, value)
  end

  defp put_hsts(conn, nil), do: conn

  defp put_hsts(conn, {:always, value}),
    do: put_resp_header(conn, "strict-transport-security", value)

  defp put_hsts(%Plug.Conn{scheme: :https} = conn, {:https, value}),
    do: put_resp_header(conn, "strict-transport-security", value)

  defp put_hsts(conn, {:https, _value}), do: conn

  ## Option compilation

  defp static_headers(opts) do
    [
      {"permissions-policy", :permissions_policy},
      {"referrer-policy", :referrer_policy},
      {"x-content-type-options", :content_type_options},
      {"x-frame-options", :frame_options}
    ]
    |> Enum.flat_map(fn {header, key} ->
      case Keyword.fetch!(opts, key) do
        false -> []
        nil -> []
        value when is_binary(value) -> [{header, header_value!(value, key)}]
        other -> invalid!(key, other)
      end
    end)
  end

  defp csp_header(opts) do
    mode = Keyword.fetch!(opts, :csp_mode)

    name =
      case mode do
        :enforce -> @csp_header
        :report_only -> @csp_report_only_header
        other -> invalid!(:csp_mode, other)
      end

    case Keyword.fetch!(opts, :content_security_policy) do
      false ->
        nil

      policy ->
        value =
          policy
          |> build_policy()
          |> append_report_uri(Keyword.fetch!(opts, :csp_report_uri))
          |> header_value!(:content_security_policy)

        {name, value}
    end
  end

  defp build_policy(policy) when is_binary(policy), do: String.trim(policy)

  defp build_policy(policy) when is_list(policy) do
    Enum.map_join(policy, "; ", fn
      {directive, value} when is_atom(directive) -> directive(directive, value)
      other -> invalid!(:content_security_policy, other)
    end)
  end

  defp build_policy(other), do: invalid!(:content_security_policy, other)

  defp directive(name, true), do: directive_name(name)
  defp directive(name, source) when is_binary(source), do: directive(name, [source])

  defp directive(name, sources) when is_list(sources) and sources != [] do
    Enum.each(sources, &source!(name, &1))
    Enum.join([directive_name(name) | sources], " ")
  end

  defp directive(name, other), do: invalid!(name, other)

  defp directive_name(name), do: name |> Atom.to_string() |> String.replace("_", "-")

  defp source!(name, source) when is_binary(source) do
    if source == "" or String.contains?(source, [";", ",", " "]) do
      invalid!(name, source)
    end
  end

  defp source!(name, other), do: invalid!(name, other)

  defp append_report_uri(policy, nil), do: policy

  defp append_report_uri(policy, uri) when is_binary(uri) do
    source!(:csp_report_uri, uri)

    if String.contains?(policy, "report-uri") do
      policy
    else
      String.trim_trailing(policy, ";") <> "; report-uri " <> uri
    end
  end

  defp append_report_uri(_policy, other), do: invalid!(:csp_report_uri, other)

  defp hsts_header(opts) do
    case Keyword.fetch!(opts, :hsts) do
      false -> nil
      mode when mode in [:https, :always] -> {mode, hsts_value(opts)}
      other -> invalid!(:hsts, other)
    end
  end

  defp hsts_value(opts) do
    max_age = Keyword.fetch!(opts, :hsts_max_age)

    if !(is_integer(max_age) and max_age >= 0), do: invalid!(:hsts_max_age, max_age)

    ["max-age=#{max_age}"]
    |> append_if(Keyword.fetch!(opts, :hsts_include_subdomains), "includeSubDomains")
    |> append_if(Keyword.fetch!(opts, :hsts_preload), "preload")
    |> Enum.join("; ")
  end

  defp append_if(parts, true, value), do: parts ++ [value]
  defp append_if(parts, _flag, _value), do: parts

  defp header_value!(value, key) do
    if String.match?(value, ~r/[\x00-\x1f\x7f]/), do: invalid!(key, value), else: value
  end

  @spec invalid!(atom(), term()) :: no_return()
  defp invalid!(key, value) do
    raise ArgumentError, "invalid #{inspect(key)} for #{inspect(__MODULE__)}: #{inspect(value)}"
  end
end
