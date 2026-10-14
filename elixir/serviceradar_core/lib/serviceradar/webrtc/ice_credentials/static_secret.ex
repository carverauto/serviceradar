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
  which enforces the same bounded read, trailing-CR/LF strip, and
  32..512 printable-ASCII checks remote desktop uses today). Already
  loaded secrets passed in opts are used as-is.
  """

  @behaviour ServiceRadar.WebRTC.IceCredentials

  alias ServiceRadar.WebRTC.IceCredentials

  @min_secret_bytes 32
  @max_secret_bytes 512
  # Remote desktop reads at most 512 secret bytes plus a trailing CRLF.
  @max_secret_file_bytes @max_secret_bytes + 2

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
  Reads and validates a TURN shared secret file.

  Files larger than 514 bytes are rejected before the rest of the file is
  read. Only trailing CR/LF bytes are stripped. The remaining secret must
  be 32..512 printable ASCII bytes, the same contract remote desktop
  enforces. Non-text bytes return `{:error, :invalid_secret}`.
  """
  @spec load_shared_secret(Path.t()) :: {:ok, binary()} | {:error, term()}
  def load_shared_secret(path) when is_binary(path) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, io_device} ->
        try do
          with {:ok, contents} <- read_bounded_secret(io_device) do
            validate_secret_bytes(strip_trailing_crlf(contents))
          end
        after
          :file.close(io_device)
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
    chosen = opts[:shared_secret] || Keyword.get(backend_config(), :secret)

    cond do
      is_binary(chosen) and byte_size(chosen) > 0 ->
        {:ok, chosen}

      chosen ->
        {:error, :missing_secret}

      true ->
        case Keyword.get(backend_config(), :secret_file) do
          path when is_binary(path) and path != "" -> load_shared_secret(path)
          _missing -> {:error, :missing_secret}
        end
    end
  end

  defp read_bounded_secret(io_device) do
    case :file.position(io_device, :cur) do
      {:ok, 0} ->
        case :file.read(io_device, @max_secret_file_bytes + 1) do
          :eof ->
            {:ok, <<>>}

          {:ok, contents} when byte_size(contents) <= @max_secret_file_bytes ->
            case :file.read(io_device, 1) do
              :eof -> {:ok, contents}
              {:ok, _more} -> {:error, :secret_too_long}
              {:error, reason} -> {:error, reason}
            end

          {:ok, _oversized} ->
            {:error, :secret_too_long}

          {:error, reason} ->
            {:error, reason}
        end

      _non_regular ->
        {:error, :invalid_secret}
    end
  end

  defp strip_trailing_crlf(secret) do
    secret
    |> strip_trailing_byte(?\n)
    |> strip_trailing_byte(?\r)
  end

  defp strip_trailing_byte(secret, byte) do
    drop = count_trailing(secret, byte, byte_size(secret), 0)
    binary_part(secret, 0, byte_size(secret) - drop)
  end

  defp count_trailing(_secret, _byte, 0, count), do: count

  defp count_trailing(secret, byte, index, count) do
    if :binary.at(secret, index - 1) == byte do
      count_trailing(secret, byte, index - 1, count + 1)
    else
      count
    end
  end

  defp validate_secret_bytes(secret) do
    size = byte_size(secret)

    cond do
      size < @min_secret_bytes -> {:error, :secret_too_short}
      size > @max_secret_bytes -> {:error, :secret_too_long}
      not printable_ascii?(secret) -> {:error, :invalid_secret}
      true -> {:ok, secret}
    end
  end

  defp printable_ascii?(<<char, rest::binary>>) when char in ?!..?~, do: printable_ascii?(rest)
  defp printable_ascii?(<<>>), do: true
  defp printable_ascii?(_other), do: false

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
