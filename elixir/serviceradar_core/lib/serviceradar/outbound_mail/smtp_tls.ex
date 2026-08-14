defmodule ServiceRadar.OutboundMail.SmtpTls do
  @moduledoc """
  OTP 26+ refuses `verify: :verify_peer` without CA material. gen_smtp and
  Swoosh do not load the OS trust store, so STARTTLS and implicit TLS fail
  with `{:options, :incompatible, [verify: :verify_peer, cacerts: :undefined]}`.

  Attach these options whenever SMTP will speak TLS.
  """

  @spec attach(keyword()) :: keyword()
  def attach(config) when is_list(config) do
    tls = Keyword.get(config, :tls, :if_available)
    ssl? = Keyword.get(config, :ssl, false)

    if ssl? or tls in [:always, :if_available] do
      ssl_opts = client_options(tls_server_name(config))

      config
      |> Keyword.put(
        :tls_options,
        merge_ssl_opts(Keyword.get(config, :tls_options, []), ssl_opts)
      )
      |> maybe_put_sockopts(ssl?, ssl_opts)
    else
      config
    end
  end

  @spec client_options(String.t() | nil) :: keyword()
  def client_options(server_name) do
    put_hostname_opts([verify: :verify_peer, cacerts: cacerts(), depth: 10], server_name)
  end

  defp maybe_put_sockopts(config, true, ssl_opts) do
    Keyword.put(config, :sockopts, merge_ssl_opts(Keyword.get(config, :sockopts, []), ssl_opts))
  end

  defp maybe_put_sockopts(config, _ssl?, _ssl_opts), do: config

  defp merge_ssl_opts(existing, defaults) when is_list(existing) do
    Keyword.merge(defaults, existing)
  end

  defp merge_ssl_opts(_existing, defaults), do: defaults

  defp tls_server_name(config) do
    Enum.find([Keyword.get(config, :hostname), Keyword.get(config, :relay)], &dns_name?/1)
  end

  defp put_hostname_opts(opts, name) do
    if dns_name?(name) do
      opts
      |> Keyword.put(:server_name_indication, String.to_charlist(name))
      |> Keyword.put(:customize_hostname_check,
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      )
    else
      Keyword.put(opts, :server_name_indication, :disable)
    end
  end

  defp dns_name?(value) when is_binary(value) do
    host = String.trim(value)
    host != "" and not ip_literal?(host)
  end

  defp dns_name?(_value), do: false

  defp ip_literal?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _address} -> true
      {:error, _reason} -> false
    end
  end

  defp cacerts do
    case :public_key.cacerts_get() do
      certs when is_list(certs) and certs != [] -> certs
      _other -> []
    end
  rescue
    _exception -> []
  end
end
