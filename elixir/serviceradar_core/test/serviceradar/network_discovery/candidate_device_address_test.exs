defmodule ServiceRadar.NetworkDiscovery.CandidateDeviceAddressTest do
  @moduledoc """
  A device record is never minted for an address that cannot identify a device.

  Observed on demo: 169.254.0.1 -- an APIPA address reported on switchcff8f2's
  own interface -- became device sr:b53d5a38 with no hostname and no MAC. It was
  self-sustaining: once the record existed, sweep picked it up as a target and
  revived it through the undelete path, clearing the deleted_reason set by a
  manual cleanup. Deleting it by hand could not win while something kept
  re-creating it.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor

  test "routable addresses may seed a candidate device" do
    for ip <- ["192.168.1.143", "10.0.2.13", "152.117.116.178", "2001:470:c0b5:1::1"] do
      assert MapperResultsIngestor.candidate_device_address?(ip), "expected #{ip} to be allowed"
    end
  end

  test "link-local never seeds a device" do
    # The observed case, plus its IPv6 counterpart. Every device has these.
    for ip <- ["169.254.0.1", "169.254.255.254", "fe80::1", "fe80::f692:bfff:fe75:c72a"] do
      refute MapperResultsIngestor.candidate_device_address?(ip), "expected #{ip} to be rejected"
    end
  end

  test "loopback and unspecified never seed a device" do
    for ip <- ["127.0.0.1", "::1", "0.0.0.0", "::"] do
      refute MapperResultsIngestor.candidate_device_address?(ip), "expected #{ip} to be rejected"
    end
  end

  test "non-addresses never seed a device" do
    for value <- ["not-an-ip", "", nil] do
      refute MapperResultsIngestor.candidate_device_address?(value)
    end
  end
end
