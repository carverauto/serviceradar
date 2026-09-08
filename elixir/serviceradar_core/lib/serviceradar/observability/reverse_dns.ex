defmodule ServiceRadar.Observability.ReverseDns do
  @moduledoc """
  Reverse DNS (PTR) lookups with a strict per-lookup timeout.

  Used by flow IP enrichment and the scheduled device hostname job.
  """

  @default_timeout_ms 250

  @type status :: String.t()
  @type lookup_result :: {String.t() | nil, status(), String.t() | nil}

  @doc """
  Look up a PTR record for `ip`.

  Returns `{hostname, status, error}` so callers can cache both successes and
  failures without raising. `status` is `"ok"`, `"timeout"`, or `"error"`.
  """
  @spec lookup_status(String.t(), keyword()) :: lookup_result()
  def lookup_status(ip, opts \\ [])

  def lookup_status(ip, opts) when is_binary(ip) do
    timeout_ms = opts[:timeout_ms] || @default_timeout_ms
    resolver = opts[:resolver] || (&reverse_dns/1)

    case parse_ip(ip) do
      {:ok, ip_tuple} ->
        task = Task.async(fn -> resolver.(ip_tuple) end)

        case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, {:ok, hostname}} ->
            case normalize_hostname(hostname) do
              {:ok, normalized} -> {normalized, "ok", nil}
              {:error, reason} -> {nil, "error", reason}
            end

          {:ok, {:error, reason}} ->
            {nil, "error", inspect(reason)}

          nil ->
            {nil, "timeout", "timeout"}
        end

      {:error, reason} ->
        {nil, "error", reason}
    end
  end

  def lookup_status(_ip, _opts), do: {nil, "error", "invalid_ip"}

  @doc """
  Parse an IPv4/IPv6 address, ignoring an optional CIDR suffix.
  """
  @spec parse_ip(String.t()) :: {:ok, :inet.ip_address()} | {:error, String.t()}
  def parse_ip(ip) when is_binary(ip) do
    ip = ip |> String.trim() |> String.split("/", parts: 2) |> List.first()

    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, tuple} -> {:ok, tuple}
      {:error, _} -> {:error, "invalid_ip"}
    end
  end

  def parse_ip(_), do: {:error, "invalid_ip"}

  @doc """
  Normalize a DNS hostname from `:inet.gethostbyaddr/1`.
  """
  @spec normalize_hostname(term()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize_hostname(hostname) when is_list(hostname) do
    normalize_hostname(List.to_string(hostname))
  end

  def normalize_hostname(hostname) when is_binary(hostname) do
    normalized =
      hostname
      |> String.trim()
      |> String.trim_trailing(".")

    cond do
      normalized == "" ->
        {:error, "blank_hostname"}

      byte_size(normalized) > 253 ->
        {:error, "hostname_too_long"}

      true ->
        {:ok, normalized}
    end
  end

  def normalize_hostname(_), do: {:error, "invalid_hostname"}

  @doc """
  True when `hostname` is a usable PTR result for `ip` (not blank, not the IP).
  """
  @spec usable_hostname?(String.t() | nil, String.t() | nil) :: boolean()
  def usable_hostname?(hostname, ip) when is_binary(hostname) do
    case normalize_hostname(hostname) do
      {:ok, normalized} ->
        ip = ip |> to_string() |> String.trim()

        normalized != "" and String.downcase(normalized) != String.downcase(ip) and
          not ip_string?(normalized)

      {:error, _} ->
        false
    end
  end

  def usable_hostname?(_hostname, _ip), do: false

  @doc """
  True when the current device hostname should be replaced by a PTR result.
  """
  @spec missing_or_ip_hostname?(String.t() | nil, String.t() | nil) :: boolean()
  def missing_or_ip_hostname?(hostname, _ip) when hostname in [nil, ""], do: true

  def missing_or_ip_hostname?(hostname, ip) when is_binary(hostname) do
    trimmed = String.trim(hostname)
    trimmed == "" or ip_string?(trimmed) or same_ip?(trimmed, ip)
  end

  def missing_or_ip_hostname?(_hostname, _ip), do: true

  defp reverse_dns(ip_tuple) do
    case :inet.gethostbyaddr(ip_tuple) do
      {:ok, {:hostent, hostname, _aliases, _addrtype, _len, _addrs}} ->
        {:ok, hostname}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ip_string?(value) when is_binary(value) do
    match?({:ok, _}, parse_ip(value))
  end

  defp same_ip?(left, right) when is_binary(left) and is_binary(right) do
    String.downcase(String.trim(left)) == String.downcase(String.trim(right))
  end

  defp same_ip?(_left, _right), do: false
end
