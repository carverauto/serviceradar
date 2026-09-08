defmodule ServiceRadarAgentGateway.MediaIdentity do
  @moduledoc false

  require Logger

  def required_agent_id(value) do
    case value do
      nil ->
        raise GRPC.RPCError, status: :invalid_argument, message: "agent_id is required"

      value ->
        case value |> to_string() |> String.trim() do
          "" ->
            raise GRPC.RPCError, status: :invalid_argument, message: "agent_id is required"

          agent_id ->
            agent_id
        end
    end
  end

  def required_string(value, field_name) do
    case value |> to_string() |> String.trim() do
      "" ->
        raise ArgumentError, "#{field_name} is required"

      normalized ->
        normalized
    end
  end

  def gateway_id, do: Atom.to_string(node())

  def resolve_partition(identity), do: Map.get(identity, :partition_id, "default")

  def enforce_component_identity!(identity, component_id, allowed_types) do
    cert_component_id = Map.get(identity, :component_id)
    cert_component_type = Map.get(identity, :component_type)

    cond do
      cert_component_id != component_id ->
        raise GRPC.RPCError, status: :permission_denied, message: "component identity mismatch"

      cert_component_type not in allowed_types ->
        raise GRPC.RPCError, status: :permission_denied, message: "component type is not allowed"

      true ->
        :ok
    end
  end

  def extract_identity_from_stream(stream, resolver, log_label) do
    with {:ok, cert_der} <- get_peer_cert(stream),
         {:ok, identity} <- resolver.resolve_from_cert(cert_der) do
      identity
    else
      {:error, reason} ->
        Logger.warning("#{log_label} certificate validation failed: #{inspect(reason)}")
        raise GRPC.RPCError, status: :unauthenticated, message: "invalid client certificate"
    end
  end

  defp get_peer_cert(stream) do
    adapter = stream.adapter
    payload = stream.payload

    if is_atom(adapter) and Code.ensure_loaded?(adapter) and function_exported?(adapter, :get_cert, 1) do
      case adapter.get_cert(payload) do
        :undefined -> {:error, :no_certificate}
        cert_der when is_binary(cert_der) -> {:ok, cert_der}
        other -> {:error, {:unexpected_cert_result, other}}
      end
    else
      {:error, {:cert_extraction_unsupported, adapter}}
    end
  rescue
    error -> {:error, {:extraction_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:extraction_failed, kind, inspect(reason)}}
  end
end
