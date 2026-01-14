defmodule ServiceRadar.SPIFFE.WorkloadAPI do
  @moduledoc false

  import Bitwise

  alias ServiceRadar.SPIFFE.Workload.API.Stub
  alias ServiceRadar.SPIFFE.Workload.X509SVID
  alias ServiceRadar.SPIFFE.Workload.X509SVIDRequest
  alias ServiceRadar.SPIFFE.Workload.X509SVIDResponse

  @default_timeout 5_000

  @spec fetch_x509_svid(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_x509_svid(socket, opts \\ []) when is_binary(socket) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    trust_domain = Keyword.get(opts, :trust_domain)
    target = workload_api_target(socket)

    with {:ok, socket_path} <- workload_api_socket_path(socket),
         true <- File.exists?(socket_path) || {:error, {:workload_api_unavailable, socket_path}} do
      case GRPC.Stub.connect(target, adapter_opts: [connect_timeout: timeout]) do
        {:ok, channel} ->
          try do
            with {:ok, response} <- fetch_first_response(channel, timeout),
                 {:ok, svid} <- select_svid(response, trust_domain),
                 {:ok, certs} <- decode_der_chain(svid.x509_svid),
                 {:ok, cacerts} <- decode_der_chain(svid.bundle),
                 {:ok, key} <- decode_private_key(svid.x509_svid_key) do
              {:ok, %{certs: certs, cacerts: cacerts, key: key, spiffe_id: svid.spiffe_id}}
            end
          after
            safe_disconnect(channel)
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :workload_api_socket_missing}
      {:error, _reason} = error -> error
      other -> {:error, other}
    end
  end

  defp fetch_first_response(channel, timeout) do
    metadata = %{"workload.spiffe.io" => "true"}

    case Stub.fetch_x509_svid(channel, %X509SVIDRequest{}, timeout: timeout, metadata: metadata) do
      {:ok, replies} ->
        replies
        |> Enum.take(1)
        |> List.first()
        |> normalize_reply()

      {:ok, replies, _trailers} ->
        replies
        |> Enum.take(1)
        |> List.first()
        |> normalize_reply()

      {:error, _reason} = error ->
        error
    end
  end

  defp normalize_reply({:ok, %X509SVIDResponse{} = response}), do: {:ok, response}
  defp normalize_reply({:error, reason}), do: {:error, reason}
  defp normalize_reply(nil), do: {:error, :workload_api_empty_response}
  defp normalize_reply({:trailers, _}), do: {:error, :workload_api_no_svids}

  defp select_svid(%X509SVIDResponse{svids: svids}, trust_domain) do
    svid =
      case trust_domain do
        nil ->
          List.first(svids)

        domain ->
          Enum.find(svids, fn %X509SVID{spiffe_id: spiffe_id} ->
            String.starts_with?(spiffe_id, "spiffe://#{domain}/")
          end) || List.first(svids)
      end

    case svid do
      %X509SVID{} -> {:ok, svid}
      _ -> {:error, :workload_api_no_svids}
    end
  end

  defp workload_api_target(socket) do
    case URI.parse(socket) do
      %URI{scheme: "unix", path: path} when is_binary(path) ->
        "unix:#{path}"

      %URI{scheme: "unix"} ->
        socket

      %URI{scheme: nil} ->
        socket

      _ ->
        socket
    end
  end

  defp workload_api_socket_path(socket) do
    case URI.parse(socket) do
      %URI{scheme: "unix", path: path} when is_binary(path) ->
        {:ok, path}

      %URI{scheme: nil} ->
        {:ok, socket}

      %URI{scheme: "unix"} ->
        {:ok, socket}

      other ->
        {:error, {:invalid_workload_api_socket, other}}
    end
  end

  defp decode_der_chain(der) when is_binary(der) do
    case split_der_chain(der, []) do
      [] -> {:error, :invalid_der_chain}
      certs -> {:ok, certs}
    end
  end

  defp decode_private_key(der) when is_binary(der) do
    try do
      _ = :public_key.der_decode(:PrivateKeyInfo, der)
      {:ok, {:PrivateKeyInfo, der}}
    rescue
      _ -> {:error, :invalid_private_key}
    catch
      _ -> {:error, :invalid_private_key}
    end
  end

  defp split_der_chain(<<>>, acc), do: Enum.reverse(acc)

  defp split_der_chain(<<0x30, rest::binary>> = data, acc) do
    case decode_der_length(rest) do
      {:ok, length, header_size} ->
        total = 1 + header_size + length

        if byte_size(data) < total do
          []
        else
          <<cert::binary-size(total), remaining::binary>> = data
          split_der_chain(remaining, [cert | acc])
        end

      {:error, _} ->
        []
    end
  end

  defp split_der_chain(_data, _acc), do: []

  defp decode_der_length(<<len, _rest::binary>>) when len < 0x80 do
    {:ok, len, 1}
  end

  defp decode_der_length(<<len, rest::binary>>) when len >= 0x80 do
    length_size = len &&& 0x7F

    case rest do
      <<length_bytes::binary-size(length_size), _::binary>> ->
        length = :binary.decode_unsigned(length_bytes)
        {:ok, length, 1 + length_size}

      _ ->
        {:error, :invalid_length}
    end
  end

  defp safe_disconnect(channel) do
    try do
      _ = GRPC.Stub.disconnect(channel)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end
end
