defmodule Palisade.ClientIP do
  @moduledoc """
  Resolves the client address of a request from the socket peer.

  `X-Forwarded-For` is read only when the socket peer is inside one of the
  configured trusted proxy CIDRs. Anyone can send the header, so trusting it
  from any other peer would let a client choose the address that rate limits
  and audit logs record.

  When the peer is trusted, the chain is walked from the right (the hop the
  nearest proxy appended) and the first address outside the trusted CIDRs is
  the client. The socket peer is used instead when:

    * the header is absent, or sent more than `:max_headers` times,
    * the combined header value is longer than `:max_header_bytes`,
    * the chain has more than `:max_addresses` entries,
    * the walk reaches an entry that is not an IP address before finding an
      untrusted one, or
    * every entry is a trusted proxy (usually a misconfiguration: the trusted
      list includes the range real clients connect from).

  Entries may carry a port (`203.0.113.9:4711`, `[2001:db8::1]:443`); it is
  ignored. An IPv4-mapped IPv6 result (`::ffff:203.0.113.9`) is returned as
  the IPv4 address, so a client is keyed the same way on IPv4 and dual-stack
  listeners.

  ## Options

    * `:trusted_proxies` - CIDR strings whose peers may set the header.
      Default `[]`, which means the header is never read.
    * `:header` - lowercase header name. Default `"x-forwarded-for"`.
    * `:max_header_bytes` - default `1024`.
    * `:max_addresses` - default `16`.
    * `:max_headers` - default `4`.

  Options can be passed as a keyword list to every call, or validated once
  with `new/1` and the resulting struct passed instead.
  """

  import Plug.Conn

  alias Palisade.NetworkAddressPolicy

  @peer_private_key :palisade_peer_ip

  defstruct trusted_proxies: [],
            header: "x-forwarded-for",
            max_header_bytes: 1024,
            max_addresses: 16,
            max_headers: 4

  @type t :: %__MODULE__{
          trusted_proxies: [String.t()],
          header: String.t(),
          max_header_bytes: pos_integer(),
          max_addresses: pos_integer(),
          max_headers: pos_integer()
        }

  @type options :: t() | keyword()

  @doc """
  Validates options into a `t:t/0`. Raises `ArgumentError` on an unknown
  option, a non-positive bound, or a trusted proxy entry that is not a CIDR.
  """
  @spec new(options()) :: t()
  def new(%__MODULE__{} = config), do: config

  def new(opts) when is_list(opts) do
    config = struct!(__MODULE__, opts)

    for key <- [:max_header_bytes, :max_addresses, :max_headers] do
      value = Map.fetch!(config, key)
      if !(is_integer(value) and value > 0), do: invalid!(key, value)
    end

    if !(is_binary(config.header) and config.header == String.downcase(config.header)) do
      invalid!(:header, config.header)
    end

    validate_cidrs!(config.trusted_proxies)
    config
  end

  @doc """
  Returns the client address for `conn`.

  If `Palisade.Plug.RemoteIP` already ran, `conn.remote_ip` holds the
  resolved address and is returned as is.
  """
  @spec from_conn(Plug.Conn.t(), options()) :: :inet.ip_address()
  def from_conn(%Plug.Conn{} = conn, opts \\ []) do
    if Map.has_key?(conn.private, @peer_private_key) do
      conn.remote_ip
    else
      config = new(opts)
      resolve(conn.remote_ip, get_req_header(conn, config.header), config)
    end
  end

  @doc """
  Returns the client address for a LiveView socket's connect info.

  Pass the map from `Phoenix.LiveView.get_connect_info/2`-enabled sockets,
  for example `socket.private.connect_info`, or a map built from
  `get_connect_info(socket, :peer_data)` and
  `get_connect_info(socket, :x_headers)`. The endpoint's socket must declare
  `connect_info: [:peer_data, :x_headers]`.

  Returns `nil` when the connect info carries no peer address, as on the
  disconnected (HTTP) render.
  """
  @spec from_connect_info(map() | keyword() | nil, options()) :: :inet.ip_address() | nil
  def from_connect_info(connect_info, opts \\ [])

  def from_connect_info(connect_info, opts) when is_list(connect_info),
    do: from_connect_info(Map.new(connect_info), opts)

  def from_connect_info(%{peer_data: %{address: peer}} = connect_info, opts)
      when is_tuple(peer) do
    config = new(opts)

    values =
      for {name, value} <- Map.get(connect_info, :x_headers) || [],
          String.downcase(name) == config.header,
          do: value

    resolve(peer, values, config)
  end

  def from_connect_info(_connect_info, _opts), do: nil

  @doc """
  Resolves the client address from the socket `peer` and the values of every
  forwarding header the request carried, in order.
  """
  @spec resolve(:inet.ip_address(), [String.t()], options()) :: :inet.ip_address()
  def resolve(peer, header_values, opts \\ []) when is_tuple(peer) and is_list(header_values) do
    config = new(opts)
    peer = unmap(peer)

    with true <- NetworkAddressPolicy.ip_in_any_cidr?(peer, config.trusted_proxies),
         {:ok, chain} <- bounded_chain(header_values, config),
         {:ok, client} <- walk(Enum.reverse(chain), config.trusted_proxies) do
      client
    else
      _ -> peer
    end
  end

  @doc "Formats an address tuple as a string."
  @spec format(:inet.ip_address()) :: String.t()
  def format(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()

  @doc false
  def peer_private_key, do: @peer_private_key

  defp bounded_chain([], _config), do: :error

  defp bounded_chain(values, config) do
    cond do
      length(values) > config.max_headers ->
        :error

      values |> Enum.map(&byte_size/1) |> Enum.sum() > config.max_header_bytes ->
        :error

      true ->
        chain =
          values
          |> Enum.join(",")
          |> :binary.split(",", [:global])
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        if length(chain) > config.max_addresses, do: :error, else: {:ok, chain}
    end
  end

  # Right to left: skip trusted proxies, stop at the first untrusted address.
  # A malformed entry ends the walk without a result.
  defp walk([], _trusted), do: :error

  defp walk([entry | rest], trusted) do
    case parse_entry(entry) do
      {:ok, ip} ->
        if NetworkAddressPolicy.ip_in_any_cidr?(ip, trusted),
          do: walk(rest, trusted),
          else: {:ok, ip}

      :error ->
        :error
    end
  end

  defp parse_entry(entry) do
    entry
    |> strip_port()
    |> String.to_charlist()
    |> :inet.parse_strict_address()
    |> case do
      {:ok, ip} -> {:ok, unmap(ip)}
      {:error, _} -> :error
    end
  end

  defp strip_port("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [address, ""] -> address
      [address, ":" <> port] -> if port?(port), do: address, else: ""
      _ -> ""
    end
  end

  defp strip_port(entry) do
    case String.split(entry, ":") do
      [address, port] -> if port?(port), do: address, else: ""
      _ -> entry
    end
  end

  defp port?(port), do: port != "" and byte_size(port) <= 5 and String.match?(port, ~r/\A\d+\z/)

  defp unmap({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do:
      {Bitwise.bsr(high, 8), Bitwise.band(high, 0xFF), Bitwise.bsr(low, 8),
       Bitwise.band(low, 0xFF)}

  defp unmap(ip), do: ip

  defp validate_cidrs!(cidrs) when is_list(cidrs) do
    Enum.each(cidrs, fn cidr ->
      if !(is_binary(cidr) and valid_cidr?(cidr)), do: invalid!(:trusted_proxies, cidr)
    end)
  end

  defp validate_cidrs!(other), do: invalid!(:trusted_proxies, other)

  # A CIDR is well formed when its own base address is inside it.
  defp valid_cidr?(cidr) do
    with [base, _bits] <- String.split(String.trim(cidr), "/", parts: 2),
         {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(base)) do
      NetworkAddressPolicy.cidr_contains?(ip, cidr)
    else
      _ -> false
    end
  end

  @spec invalid!(atom(), term()) :: no_return()
  defp invalid!(key, value) do
    raise ArgumentError, "invalid #{inspect(key)} for #{inspect(__MODULE__)}: #{inspect(value)}"
  end
end
