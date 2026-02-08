defmodule ServiceRadar.Types.Cidr do
  @moduledoc """
  Ash type for Postgres `cidr`/`inet` values.

  Represented as a string (e.g. "10.0.0.0/8") in Ash, stored as `:inet` in Ecto.
  """

  use Ash.Type

  @impl true
  def storage_type(_), do: :inet

  @impl true
  def matches_type?(%Postgrex.INET{}, _), do: true
  def matches_type?(value, _) when is_binary(value), do: true
  def matches_type?(_, _), do: false

  @impl true
  def cast_input("", _), do: {:ok, nil}
  def cast_input(nil, _), do: {:ok, nil}

  def cast_input(%Postgrex.INET{} = inet, _), do: {:ok, inet_to_string(inet)}

  def cast_input(value, _constraints) when is_binary(value) do
    case parse_inet(value) do
      {:ok, inet} -> {:ok, inet_to_string(inet)}
      :error -> :error
    end
  end

  def cast_input(_, _), do: :error

  @impl true
  def cast_stored(nil, _), do: {:ok, nil}
  def cast_stored(%Postgrex.INET{} = inet, _), do: {:ok, inet_to_string(inet)}
  def cast_stored(value, _) when is_binary(value), do: {:ok, value}
  def cast_stored(_, _), do: :error

  @impl true
  def dump_to_native(nil, _), do: {:ok, nil}
  def dump_to_native(%Postgrex.INET{} = inet, _), do: {:ok, inet}

  def dump_to_native(value, _constraints) when is_binary(value) do
    case parse_inet(value) do
      {:ok, inet} -> {:ok, inet}
      :error -> :error
    end
  end

  def dump_to_native(_, _), do: :error

  defp parse_inet(value) when is_binary(value) do
    value = String.trim(value)

    {ip_str, mask_str} =
      case String.split(value, "/", parts: 2) do
        [ip] -> {ip, nil}
        [ip, mask] -> {ip, mask}
      end

    with {:ok, ip} <- parse_ip(String.trim(ip_str)),
         {:ok, netmask} <- parse_netmask(ip, mask_str) do
      {:ok, %Postgrex.INET{address: ip, netmask: netmask}}
    else
      _ -> :error
    end
  end

  defp parse_ip(str) do
    case :inet.parse_address(to_charlist(str)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> :error
    end
  end

  defp parse_netmask(ip, nil), do: {:ok, max_mask(ip)}
  defp parse_netmask(ip, ""), do: {:ok, max_mask(ip)}

  defp parse_netmask(ip, mask_str) when is_binary(mask_str) do
    max = max_mask(ip)

    case Integer.parse(String.trim(mask_str)) do
      {mask, ""} when mask >= 0 and mask <= max -> {:ok, mask}
      _ -> :error
    end
  end

  defp max_mask({_, _, _, _}), do: 32
  defp max_mask({_, _, _, _, _, _, _, _}), do: 128

  defp inet_to_string(%Postgrex.INET{address: address, netmask: netmask}) do
    ip = address |> :inet.ntoa() |> to_string()
    "#{ip}/#{netmask}"
  end
end
