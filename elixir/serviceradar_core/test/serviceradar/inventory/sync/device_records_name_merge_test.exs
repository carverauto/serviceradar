defmodule ServiceRadar.Inventory.Sync.DeviceRecordsNameMergeTest do
  @moduledoc """
  Two updates for one device in one sync batch are merged before the upsert
  (in `DeviceRecords.build_device_upsert_records/2` and
  `DeviceRecords.merge_records_by_uid/1`), so the upsert's ranked `name` decision
  never sees the earlier one. The merge must therefore apply the same rule: an
  address-fallback name never replaces an observed name, a link-local address
  names nothing, and the same source's fallback follows its own address.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Sync.DeviceRecords
  alias ServiceRadar.Inventory.Sync.Normalize

  @timestamp ~U[2026-11-17 12:00:00Z]

  for path <- [:one_build, :merge_by_uid] do
    @path path

    test "#{path}: a hostname-less update keeps the observed name, in either order" do
      observed = %{"ip" => "192.0.2.20", "hostname" => "ap-01", "source" => "mapper"}
      sighting = %{"ip" => "192.0.2.20", "source" => "netprobe-census"}

      assert merged_name(@path, [observed, sighting]) == {"ap-01", "ap-01"}
      assert merged_name(@path, [sighting, observed]) == {"ap-01", "ap-01"}
    end

    test "#{path}: a link-local sighting does not replace an address-fallback name" do
      assert merged_name(@path, [
               %{"ip" => "192.0.2.21", "source" => "netprobe-census"},
               %{"ip" => "fe80::1", "source" => "netprobe-census"}
             ]) == {"192.0.2.21", nil}
    end

    test "#{path}: the same source's address fallback follows its address" do
      # A usable IPv4 is strictly stronger than any IPv6, so it becomes the primary.
      assert merged_name(@path, [
               %{"ip" => "2001:db8::22", "source" => "netprobe-census"},
               %{"ip" => "192.0.2.22", "source" => "netprobe-census"}
             ]) == {"192.0.2.22", nil}
    end

    test "#{path}: an equally strong later address keeps the primary and its fallback name" do
      # Equal rank never replaces the primary, so the name stays on the kept address.
      assert merged_name(@path, [
               %{"ip" => "192.0.2.22", "source" => "netprobe-census"},
               %{"ip" => "198.51.100.22", "source" => "netprobe-census"}
             ]) == {"192.0.2.22", nil}
    end
  end

  # :one_build is a census snapshot: every binding for one device in one
  # build_device_upsert_records call. :merge_by_uid builds each update alone
  # and folds the records afterwards, as a later uid remap does.
  defp merged_name(path, raw_updates) do
    resolved = Enum.map(raw_updates, &{Normalize.normalize_update(&1), "sr:device-under-test"})

    [record] =
      case path do
        :one_build ->
          DeviceRecords.build_device_upsert_records(resolved, @timestamp)

        :merge_by_uid ->
          resolved
          |> Enum.flat_map(&DeviceRecords.build_device_upsert_records([&1], @timestamp))
          |> DeviceRecords.merge_records_by_uid()
      end

    {record.name, record.hostname}
  end
end
