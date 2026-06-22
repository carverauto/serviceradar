# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
defmodule ServiceRadarWebNGWeb.DashboardLive.Data.Virtualization do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      defp virtualization_summary(srql_module, scope) do
        hosts = virtualization_rows(srql_module, scope, "virtualization_hosts")
        guests = virtualization_rows(srql_module, scope, "virtualization_guests")
        datastores = virtualization_rows(srql_module, scope, "virtualization_datastores")
        storage_systems = virtualization_rows(srql_module, scope, "virtualization_storage_systems")

        host_memory_ratios = Enum.map(hosts, &memory_ratio/1)
        guest_memory_ratios = Enum.map(guests, &memory_ratio/1)
        guest_disk_ratios = Enum.map(guests, &disk_ratio/1)
        datastore_ratios = Enum.map(datastores, &datastore_ratio/1)
        ceph_health = storage_health_summary(storage_systems)
        pressure_items = virtualization_pressure_items(hosts, guests, datastores, storage_systems)
        bottlenecks = length(pressure_items)

        %{
          available: hosts != [] or guests != [] or datastores != [] or storage_systems != [],
          host_count: length(hosts),
          guest_count: length(guests),
          running_guests: Enum.count(guests, &(normalized_status(map_value(&1, "status")) == "running")),
          stopped_guests: Enum.count(guests, &(normalized_status(map_value(&1, "status")) == "stopped")),
          datastore_count: length(datastores),
          storage_system_count: length(storage_systems),
          provider_label:
            ServiceRadarWebNGWeb.Helpers.VirtualizationLabels.provider_summary(
              hosts ++ guests ++ datastores ++ storage_systems
            ),
          avg_host_cpu_pct: avg_percent(Enum.map(hosts, &ratio_percent(map_value(&1, "cpu_ratio")))),
          max_host_cpu_pct: max_percent(Enum.map(hosts, &ratio_percent(map_value(&1, "cpu_ratio")))),
          max_host_memory_pct: max_percent(host_memory_ratios),
          max_guest_cpu_pct: max_percent(Enum.map(guests, &ratio_percent(map_value(&1, "cpu_ratio")))),
          max_guest_memory_pct: max_percent(guest_memory_ratios),
          max_guest_disk_pct: max_percent(guest_disk_ratios),
          max_datastore_pct: max_percent(datastore_ratios),
          bottleneck_count: bottlenecks,
          ceph_warning_count: ceph_health.warning_count,
          ceph_error_count: ceph_health.error_count,
          ceph_health_label: ceph_health.label,
          pressure_items: Enum.take(pressure_items, 8),
          status_label: virtualization_status_label(bottlenecks, ceph_health),
          status_tone: virtualization_status_tone(bottlenecks, ceph_health)
        }
      rescue
        _ -> empty_virtualization_summary()
      end

      defp virtualization_rows(srql_module, scope, entity) do
        case srql_module.query("in:#{entity}", %{scope: scope, limit: 500}) do
          {:ok, %{"results" => results}} when is_list(results) -> results
          _ -> []
        end
      rescue
        _ -> []
      end

      defp memory_ratio(row) when is_map(row) do
        bytes_ratio(map_value(row, "memory_used_bytes"), map_value(row, "memory_total_bytes"))
      end

      defp disk_ratio(row) when is_map(row) do
        bytes_ratio(map_value(row, "disk_used_bytes"), map_value(row, "disk_total_bytes"))
      end

      defp datastore_ratio(row) when is_map(row) do
        bytes_ratio(map_value(row, "used_bytes"), map_value(row, "total_bytes"))
      end

      defp bytes_ratio(used, total) do
        used = to_float(used)
        total = to_float(total)
        if total > 0, do: used / total * 100.0, else: 0.0
      end

      defp ratio_percent(value) do
        value = to_float(value)
        if value <= 1.0, do: value * 100.0, else: value
      end

      defp avg_percent(values) when is_list(values) do
        normalized = Enum.map(values, &clamp_percent/1)
        if normalized == [], do: 0.0, else: Float.round(Enum.sum(normalized) / length(normalized), 1)
      end

      defp max_percent(values) when is_list(values) do
        values
        |> Enum.map(&clamp_percent/1)
        |> Enum.max(fn -> 0.0 end)
        |> Float.round(1)
      end

      defp clamp_percent(value) do
        value
        |> to_float()
        |> max(0.0)
        |> min(100.0)
      end

      defp virtualization_pressure_items(hosts, guests, datastores, storage_systems) do
        host_items =
          Enum.flat_map(hosts, fn host ->
            label = display_name(host, "Hypervisor")

            [
              pressure_item(host, "Host CPU", label, ratio_percent(map_value(host, "cpu_ratio"))),
              pressure_item(host, "Host Memory", label, memory_ratio(host))
            ]
          end)

        guest_items =
          Enum.flat_map(guests, fn guest ->
            label = display_name(guest, "Guest")

            [
              pressure_item(guest, "Guest CPU", label, ratio_percent(map_value(guest, "cpu_ratio"))),
              pressure_item(guest, "Guest Memory", label, memory_ratio(guest)),
              pressure_item(guest, "Guest Disk", label, disk_ratio(guest))
            ]
          end)

        datastore_items =
          Enum.map(datastores, fn datastore ->
            host = map_value(datastore, "host_name") || map_value(datastore, "node")
            label = [display_name(datastore, "Datastore"), host] |> Enum.filter(&present?/1) |> Enum.join(" on ")

            pressure_item(datastore, "Datastore", label, datastore_ratio(datastore),
              fallback_href:
                srql_href("in:virtualization_datastores storage:\"#{escape_query_value(map_value(datastore, "name"))}\"")
            )
          end)

        storage_items =
          Enum.flat_map(storage_systems, fn system ->
            health = map_value(system, "health") || map_value(system, "status")

            cond do
              storage_health_error?(health) ->
                [health_item(system, "Storage Health", display_name(system, "Storage"), "Critical")]

              storage_health_warning?(health) ->
                [health_item(system, "Storage Health", display_name(system, "Storage"), "Warning")]

              true ->
                []
            end
          end)

        (host_items ++ guest_items ++ datastore_items ++ storage_items)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.sort_value, :desc)
      end

      defp pressure_item(row, metric, label, value, opts \\ []) do
        value = clamp_percent(value)

        if value >= 85.0 do
          %{
            metric: metric,
            label: label,
            value: value,
            value_label: "#{format_float(value)}%",
            href: device_href(row) || Keyword.get(opts, :fallback_href),
            sort_value: value
          }
        end
      end

      defp health_item(row, metric, label, value_label) do
        %{
          metric: metric,
          label: label,
          value: nil,
          value_label: value_label,
          href: device_href(row),
          sort_value: 100.0
        }
      end

      defp display_name(row, fallback) do
        map_value(row, "name") ||
          map_value(row, "node") ||
          map_value(row, "host_name") ||
          map_value(row, "provider_ref") ||
          fallback
      end

      defp device_href(row) do
        case map_value(row, "device_uid") || map_value(row, "device_id") || map_value(row, "uid") do
          value when is_binary(value) and value != "" -> "/devices/#{URI.encode_www_form(value)}"
          _ -> nil
        end
      end

      defp srql_href(query), do: "/devices?q=#{URI.encode(query)}"

      defp escape_query_value(value) do
        value
        |> to_string()
        |> String.replace("\\", "\\\\")
        |> String.replace("\"", "\\\"")
      end

      defp storage_health_summary(storage_systems) when is_list(storage_systems) do
        statuses =
          Enum.map(storage_systems, fn system ->
            map_value(system, "health") || map_value(system, "status")
          end)

        error_count = Enum.count(statuses, &storage_health_error?/1)
        warning_count = Enum.count(statuses, &storage_health_warning?/1)

        label =
          cond do
            error_count > 0 -> "#{format_count(error_count)} storage errors"
            warning_count > 0 -> "#{format_count(warning_count)} storage warnings"
            statuses == [] -> "No clustered storage"
            true -> "Storage healthy"
          end

        %{label: label, warning_count: warning_count, error_count: error_count}
      end

      defp storage_health_error?(value) do
        value
        |> normalized_status()
        |> Kernel.in(["err", "error", "critical", "failed", "health_err"])
      end

      defp storage_health_warning?(value) do
        status = normalized_status(value)
        status in ["warn", "warning", "degraded", "health_warn"] and not storage_health_error?(status)
      end

      defp normalized_status(value) when is_binary(value) do
        value
        |> String.trim()
        |> String.downcase()
      end

      defp normalized_status(value), do: value |> to_string() |> String.downcase()

      defp virtualization_status_label(0, %{error_count: 0, warning_count: 0}), do: "Efficient"
      defp virtualization_status_label(_bottlenecks, %{error_count: errors}) when errors > 0, do: "Critical"
      defp virtualization_status_label(_bottlenecks, _health), do: "Pressure"

      defp virtualization_status_tone(0, %{error_count: 0, warning_count: 0}), do: "ok"
      defp virtualization_status_tone(_bottlenecks, %{error_count: errors}) when errors > 0, do: "error"
      defp virtualization_status_tone(_bottlenecks, _health), do: "warning"
    end
  end
end
