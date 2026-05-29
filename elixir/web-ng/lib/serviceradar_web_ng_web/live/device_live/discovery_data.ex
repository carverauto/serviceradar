defmodule ServiceRadarWebNGWeb.DeviceLive.DiscoveryData do
  @moduledoc false

  import Bitwise

  alias ServiceRadar.NetworkDiscovery.MapperJob
  alias ServiceRadar.SweepJobs.SweepHostResult

  require Ash.Query

  def load_mapper_jobs_for_device(nil, _device_row), do: []
  def load_mapper_jobs_for_device(_scope, nil), do: []

  def load_mapper_jobs_for_device(scope, device_row) do
    partition =
      device_row
      |> Map.get("partition", Map.get(device_row, "partition_id", "default"))
      |> to_string()
      |> String.trim()
      |> case do
        "" -> "default"
        value -> value
      end

    ip = Map.get(device_row, "ip")
    hostname = Map.get(device_row, "hostname")

    query =
      MapperJob
      |> Ash.Query.for_read(:enabled_by_partition, %{partition: partition}, scope: scope)
      |> Ash.Query.load(:seeds)

    case Ash.read(query, scope: scope) do
      {:ok, jobs} ->
        Enum.filter(jobs, &mapper_job_targets_device?(&1, ip, hostname))

      {:error, _} ->
        []
    end
  end

  defp mapper_job_targets_device?(job, ip, hostname) do
    job
    |> mapper_job_seeds()
    |> Enum.any?(&seed_matches_device?(&1, ip, hostname))
  end

  defp mapper_job_seeds(%{seeds: %Ash.NotLoaded{}}), do: []
  defp mapper_job_seeds(%{seeds: seeds}) when is_list(seeds), do: Enum.map(seeds, & &1.seed)
  defp mapper_job_seeds(_), do: []

  defp seed_matches_device?(seed, ip, hostname) when is_binary(seed) do
    trimmed = String.trim(seed)

    cond do
      trimmed == "" ->
        false

      is_binary(ip) and trimmed == ip ->
        true

      is_binary(hostname) and String.downcase(trimmed) == String.downcase(hostname) ->
        true

      is_binary(ip) and ip_in_cidr?(ip, trimmed) ->
        true

      true ->
        false
    end
  end

  defp seed_matches_device?(_, _ip, _hostname), do: false

  defp ip_in_cidr?(ip, cidr) when is_binary(ip) and is_binary(cidr) do
    with {:ok, ip_tuple} <- parse_ip(ip),
         {:ok, cidr_ip, prefix} <- parse_cidr(cidr),
         true <- tuple_size(ip_tuple) == tuple_size(cidr_ip) do
      mask_bits = prefix
      ip_int = tuple_to_int(ip_tuple)
      cidr_int = tuple_to_int(cidr_ip)

      max_bits = tuple_size(ip_tuple) * bits_per_segment(ip_tuple)
      mask = mask_for_bits(max_bits, mask_bits)

      (ip_int &&& mask) == (cidr_int &&& mask)
    else
      _ -> false
    end
  end

  defp ip_in_cidr?(_, _), do: false

  defp parse_ip(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, tuple} -> {:ok, tuple}
      _ -> :error
    end
  end

  defp parse_cidr(cidr) do
    case String.split(cidr, "/") do
      [ip, prefix_str] ->
        with {:ok, ip_tuple} <- parse_ip(ip),
             {prefix, ""} <- Integer.parse(prefix_str) do
          {:ok, ip_tuple, prefix}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp tuple_to_int(tuple) when tuple_size(tuple) == 4 do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(0, fn octet, acc -> acc * 256 + octet end)
  end

  defp tuple_to_int(tuple) when tuple_size(tuple) == 8 do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(0, fn segment, acc -> acc * 65_536 + segment end)
  end

  defp bits_per_segment(tuple) when tuple_size(tuple) == 4, do: 8
  defp bits_per_segment(tuple) when tuple_size(tuple) == 8, do: 16

  defp mask_for_bits(_max_bits, 0), do: 0

  defp mask_for_bits(max_bits, bits) when bits >= max_bits do
    (1 <<< max_bits) - 1
  end

  defp mask_for_bits(max_bits, bits) do
    ((1 <<< bits) - 1) <<< (max_bits - bits)
  end

  def pick_discovery_job([]), do: nil

  def pick_discovery_job(jobs) do
    Enum.max_by(jobs, &mapper_job_sort_key/1, fn -> nil end)
  end

  defp mapper_job_sort_key(%{last_run_at: %DateTime{} = dt}), do: dt

  defp mapper_job_sort_key(%{last_run_at: %NaiveDateTime{} = dt}) do
    DateTime.from_naive!(dt, "Etc/UTC")
  end

  defp mapper_job_sort_key(_), do: DateTime.from_unix!(0)

  def load_sweep_results(_scope, nil), do: nil

  def load_sweep_results(scope, ip) when is_binary(ip) do
    actor = build_sweep_actor(scope)

    query =
      SweepHostResult
      |> Ash.Query.for_read(:by_ip, %{ip: ip}, actor: actor)
      |> Ash.Query.load(:execution)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(10)

    case Ash.read(query, authorize?: true) do
      {:ok, results} when results != [] ->
        %{results: results, total: length(results)}

      _ ->
        nil
    end
  end

  def load_sweep_results(_scope, _), do: nil

  defp build_sweep_actor(scope) do
    case scope do
      %{user: user} when not is_nil(user) ->
        %{
          id: user.id,
          email: user.email,
          role: user.role
        }

      _ ->
        %{
          id: "system",
          email: "system@serviceradar",
          role: :admin
        }
    end
  end
end
