defmodule Palisade.OutboundFetchTest do
  @moduledoc """
  Unit tests for the IP-pinning fetch helper. Live HTTP is out of
  scope here — tests exercise `build_request/3` to confirm the
  request is correctly rewritten to target the resolved IP while
  keeping the `Host:` header on the original hostname.
  """
  use ExUnit.Case, async: true

  alias Palisade.OutboundFetch

  describe "build_request/3 — rejected URLs" do
    test "non-https scheme" do
      assert {:error, :disallowed_scheme} =
               OutboundFetch.build_request(:get, "http://1.1.1.1/foo")
    end

    test "loopback host" do
      assert {:error, :disallowed_host} =
               OutboundFetch.build_request(:get, "https://localhost/foo")
    end

    test "private IPv4 literal" do
      assert {:error, :disallowed_host} =
               OutboundFetch.build_request(:get, "https://10.0.0.1/foo")
    end

    test "private IP via resolved_address opt is rejected too" do
      # Even if a caller pre-resolves to a private IP, OutboundFetch
      # re-checks before binding the request.
      assert {:error, :disallowed_host} =
               OutboundFetch.build_request(:get, "https://example.com/foo",
                 resolved_address: {10, 0, 0, 1}
               )
    end

    test "non-allowlisted ports are rejected before request construction" do
      assert {:error, :disallowed_port} =
               OutboundFetch.build_request(:get, "https://1.1.1.1:8443/foo",
                 resolved_address: {1, 1, 1, 1}
               )
    end
  end

  describe "build_request/3 — rewrites URL to resolved IP" do
    test "host in URL is replaced with the resolved IP literal" do
      address = {1, 2, 3, 4}

      {:ok, request} =
        OutboundFetch.build_request(:get, "https://1.1.1.1/foo", resolved_address: address)

      assert request.url.host == "1.2.3.4"
      assert request.url.scheme == "https"
      assert request.url.path == "/foo"
    end

    test "Host: header carries the original host (here, the IP literal)" do
      address = {5, 6, 7, 8}

      # Using an IP-literal host keeps the test offline (no DNS).
      # The "original hostname" semantic is still exercised — the
      # Host header is whatever was in the URL, distinct from the
      # IP the request actually connects to.
      {:ok, request} =
        OutboundFetch.build_request(:get, "https://1.1.1.1/x", resolved_address: address)

      assert request.url.host == "5.6.7.8"

      host_header =
        request.headers
        |> Enum.find_value(fn
          {"host", values} when is_list(values) -> List.first(values)
          {"host", value} -> value
          _ -> nil
        end)

      assert host_header == "1.1.1.1"
    end

    test "non-default port appears in Host header" do
      address = {5, 6, 7, 8}

      {:ok, request} =
        OutboundFetch.build_request(:get, "https://1.1.1.1:8443/x",
          resolved_address: address,
          allowed_ports: [443, 8443]
        )

      host_header =
        request.headers
        |> Enum.find_value(fn
          {"host", values} when is_list(values) -> List.first(values)
          {"host", value} -> value
          _ -> nil
        end)

      assert host_header == "1.1.1.1:8443"
    end
  end

  describe "build_request/3 — request options" do
    test "TLS hostname stays the original host (not the IP) for SNI" do
      address = {5, 6, 7, 8}

      {:ok, request} =
        OutboundFetch.build_request(:get, "https://1.1.1.1/x", resolved_address: address)

      connect_options = Map.get(request.options, :connect_options, [])
      assert Keyword.get(connect_options, :hostname) == "1.1.1.1"
    end

    test "redirects disabled by default" do
      address = {5, 6, 7, 8}

      {:ok, request} =
        OutboundFetch.build_request(:get, "https://1.1.1.1/x", resolved_address: address)

      assert Map.get(request.options, :redirect) == false
    end

    test "redirects stay disabled even if caller opts try to enable them" do
      address = {5, 6, 7, 8}

      {:ok, request} =
        OutboundFetch.build_request(:get, "https://1.1.1.1/x",
          resolved_address: address,
          redirect: true
        )

      assert Map.get(request.options, :redirect) == false
    end

    test "IPv6 address sets inet6 transport option" do
      address = {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}

      {:ok, request} =
        OutboundFetch.build_request(:get, "https://1.1.1.1/x", resolved_address: address)

      assert Map.get(request.options, :inet6) == true
    end
  end

  describe "req_opts/0" do
    test "returns conservative defaults" do
      opts = OutboundFetch.req_opts()
      assert Keyword.get(opts, :redirect) == false
      assert Keyword.get(opts, :receive_timeout) == 10_000
      assert get_in(opts, [:connect_options, :timeout]) == 5_000
    end
  end
end
