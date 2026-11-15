# Run with the qualification release; credentials stay in a private config file.
# This probe never publishes catalog entries or authorizes local reclamation.
defmodule LongshoreRoundTrip do
  @moduledoc false
  alias ServiceRadarObjectStorage, as: Storage

  @fields ~w(host port region bucket access_key secret_key session_token tls concurrency buffer_size)a
  @timeout 300_000

  def run do
    ensure_direct_egress!()
    config = config!(System.fetch_env!("LONGSHORE_QUAL_CONFIG"))
    input = System.fetch_env!("LONGSHORE_QUAL_INPUT")
    output = System.fetch_env!("LONGSHORE_QUAL_OUTPUT")
    if File.exists?(output), do: raise("output already exists; choose a new path")

    bytes = input!(input, config.buffer_size)
    size = byte_size(bytes)
    digest = :crypto.hash(:sha256, bytes)
    object_name = "qualification/longshore/" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower) <> ".mp4"
    client = open!(config)

    # Report the disposable object's identity before dispatch so unknown outcomes
    # can be inspected without repeating the upload.
    IO.puts("object_key=" <> object_name)

    try do
      case await!(Storage.put(client, object_name, bytes), :put) do
        {:ok, :stored} -> :ok
        {:ok, :already_exists} -> raise("conditional key collision; no replacement attempted")
        _ -> raise("PUT outcome unknown; preserve the input and inspect the object")
      end

      fetched = fetched!(await!(Storage.fetch(client, object_name), :fetch))

      if byte_size(fetched) != size or :crypto.hash(:sha256, fetched) != digest,
        do: raise("full readback differs from the input")

      last = min(size, 131_072) - 1
      ranged = fetched!(await!(Storage.fetch_range(client, object_name, 0, last), :range))
      if ranged != binary_part(bytes, 0, last + 1), do: raise("range readback differs from the input")

      File.write!(output, fetched, [:binary, :exclusive])
      IO.puts("verified_bytes=#{size} sha256=#{Base.encode16(digest, case: :lower)}")
      IO.puts("Verified write/full/range readback. Input and object retained; no archive receipt issued.")
    after
      Storage.close(client)
    end
  end

  defp ensure_direct_egress! do
    if Enum.any?(
         ~w(SERVICERADAR_EGRESS_PROXY HTTPS_PROXY HTTP_PROXY https_proxy http_proxy),
         &(System.get_env(&1) not in [nil, ""])
       ),
       do: raise("Longshore does not support the configured proxy")
  end

  defp input!(path, limit) do
    %{type: :regular, size: size} = File.stat!(path)

    if size < 1 or size > min(limit, 16_777_216),
      do: raise("input must fit the configured buffer and the 16 MiB probe limit")

    bytes = File.read!(path)
    if byte_size(bytes) != size, do: raise("input changed while being read")
    bytes
  end

  defp config!(path) do
    %{type: :regular, size: size} = File.stat!(path)
    if size > 32_768, do: raise("configuration exceeds 32 KiB")
    raw = path |> File.read!() |> :json.decode()

    if not is_map(raw) or Enum.sort(Map.keys(raw)) != Enum.sort(Enum.map(@fields, &Atom.to_string/1)),
      do: raise("configuration must contain exactly the documented NIF fields")

    config =
      Map.new(@fields, fn field ->
        value = Map.fetch!(raw, Atom.to_string(field))
        {field, if(value == :null, do: nil, else: value)}
      end)

    if config.tls != true, do: raise("the provider probe requires TLS")

    if not is_integer(config.buffer_size) or config.buffer_size not in 8192..16_777_216,
      do: raise("invalid buffer size")

    config
  end

  defp open!(config) do
    case Storage.open(config) do
      {:ok, client} -> client
      {:error, {:io_setup_failed, detail}} -> raise("native initialization failed: " <> detail)
      _ -> raise("native initialization refused the configuration")
    end
  end

  defp await!({:ok, reference}, operation) do
    receive do
      {:longshore_reply, ^reference, result, {queue_us, operation_us}} ->
        IO.puts("#{operation}: queue_us=#{queue_us} operation_us=#{operation_us}")
        result
    after
      @timeout -> raise("#{operation} deadline exceeded; preserve the input and inspect the object")
    end
  end

  defp await!(_, operation), do: raise("#{operation} was not admitted")
  defp fetched!({:ok, bytes}) when is_binary(bytes), do: bytes
  defp fetched!(_), do: raise("object read failed")
end

LongshoreRoundTrip.run()
