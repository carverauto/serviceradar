defmodule ServiceRadar.WebRTC.IceCredentials.StaticSecret do
  @moduledoc """
  The `static_secret` ICE credential backend: TURN REST API HMAC
  credentials from a file-mounted shared secret.

  This is the scheme remote desktop ships today (coturn `use-auth-secret`
  and eturnal `secret` verify it), lifted out of web-ng into the shared
  provider:

    * `username = \"<unix_expiry>:<subject>\"` where `<subject>` is the
      caller's digest (new consumers) or the legacy raw
      `\"actor:session:viewer\"` binding (remote desktop, byte-identical
      to the previous web-ng implementation for the same inputs);
    * `credential = base64(HMAC-SHA1(secret, username))` — SHA-1 is
      required by the TURN REST scheme the servers verify.

  The secret comes from `:shared_secret` in `opts` or
  `config :serviceradar_core, #{IceCredentials}, static_secret: [..]`
  (`:secret_file` is read once per mint through `load_shared_secret/1`,
  which enforces the 32..512 byte bounds RDP uses today).
  """

  @behaviour ServiceRadar.WebRTC.IceCredentials

  alias ServiceRadar.WebRTC.IceCredentials

  @min_secret_bytes 32
  @max_secret_bytes 512

  @impl IceCredentials
  def mint(_subject, opts) do
    with {:ok, secret} <- shared_secret(opts),
         {:ok, subject_value} <- subject_value(opts),
         {:ok, urls} <- turn_urls(opts) do
      ttl = Keyword.fetch!(opts, :ttl_seconds)
      expires_at_unix = System.system_time(:second) + ttl
      username = "#{expires_at_unix}:#{subject_value}"

      ice_servers = [
        %{
          urls: urls,
          username: username,
          credential: turn_credential(secret, username)
        }
      ]

      {:ok,
       %{
         ice_servers: ice_servers,
         expires_at: DateTime.from_unix!(expires_at_unix)
       }}
    end
  end

  @doc """
  Reads and validates a TURN shared secret file. Secrets must be 32..512
  bytes after trimming (the same bounds remote desktop enforces today).
  """
  @spec load_shared_secret(Path.t()) :: {:ok, binary()} | {:error, term()}
  def load_shared_secret(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        secret = String.trim(content)

        cond do
          byte_size(secret) < @min_secret_bytes -> {:error, :secret_too_short}
          byte_size(secret) > @max_secret_bytes -> {:error, :secret_too_long}
          true -> {:ok, secret}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The TURN REST credential: `base64(HMAC-SHA1(secret, username))`,
  byte-identical to the minting remote desktop shipped before this
  provider existed.
  """
  @spec turn_credential(binary(), binary()) :: binary()
  def turn_credential(shared_secret, username)
      when is_binary(shared_secret) and is_binary(username) do
    :hmac
    |> :crypto.mac(:sha, shared_secret, username)
    |> Base.encode64()
  end

  defp shared_secret(opts) do
    secret =
      opts[:shared_secret] ||
        Keyword.get(backend_config(), :secret) ||
        backend_config() |> Keyword.get(:secret_file) |> load_secret_file()

    case secret do
      secret when is_binary(secret) and byte_size(secret) > 0 -> {:ok, secret}
      _other -> {:error, :missing_secret}
    end
  end

  defp load_secret_file(nil), do: nil

  defp load_secret_file(path) when is_binary(path) do
    case load_shared_secret(path) do
      {:ok, secret} -> secret
      {:error, _reason} -> nil
    end
  end

  defp subject_value(opts) do
    cond do
      is_binary(opts[:legacy_subject_value]) -> {:ok, opts[:legacy_subject_value]}
      is_binary(opts[:subject_digest]) -> {:ok, opts[:subject_digest]}
      true -> {:error, :missing_binding}
    end
  end

  defp turn_urls(opts) do
    case opts[:urls] do
      urls when is_list(urls) and urls != [] ->
        if Enum.all?(urls, &turn_url?/1) do
          {:ok, urls}
        else
          {:error, :non_turn_url}
        end

      _other ->
        {:error, :missing_urls}
    end
  end

  defp turn_url?(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.downcase()
    |> then(&(String.starts_with?(&1, "turn:") || String.starts_with?(&1, "turns:")))
  end

  defp turn_url?(_url), do: false

  defp backend_config do
    :serviceradar_core
    |> Application.get_env(IceCredentials, [])
    |> Keyword.get(:static_secret, [])
  end
end
