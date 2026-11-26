defmodule ServiceRadar.Inventory.DeviceHostnameRdnsEligibleUidsDbTest do
  @moduledoc """
  The pre-filter SQL has to keep every device `candidate?/4` would accept.

  The due/not-due table below is the job rule, written out per fixture: an IP
  and a missing or IP-shaped hostname, unless overwrite is on, and outside the
  retry window unless the retry is ignored. A timestamp `DateTime.from_iso8601/1`
  cannot parse counts as never looked up. The SQL may keep a device the rule
  rejects. It may not drop one the rule accepts.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Inventory.DeviceHostnameRdns
  alias ServiceRadar.Repo

  @moduletag :integration

  @now ~U[2026-08-13 12:00:00Z]
  @variants [
    {:plain, %{overwrite_existing: false, retry_after_minutes: 1_440}, []},
    {:overwrite, %{overwrite_existing: true, retry_after_minutes: 1_440}, []},
    {:ignore_retry, %{overwrite_existing: false, retry_after_minutes: 1_440},
     [ignore_retry?: true]}
  ]

  test "the pre-filter keeps every device the job rule and candidate?/4 accept" do
    partition = "rdns-elig-#{System.unique_integer([:positive])}"
    fixtures = Enum.map(fixture_specs(), &insert_fixture!(partition, &1))

    for {variant, settings, opts} <- @variants do
      assert {:ok, uids} = DeviceHostnameRdns.eligible_device_uids(settings, @now, opts)
      returned = MapSet.new(uids)

      for fixture <- fixtures do
        due? = fixture.due[variant]

        accepted? =
          DeviceHostnameRdns.candidate?(fixture.device, settings, @now, opts)

        assert accepted? == due?,
               "#{fixture.label} #{variant}: candidate? is #{accepted?}, the rule says #{due?}"

        if due? do
          assert MapSet.member?(returned, fixture.uid),
                 "#{fixture.label} is due for #{variant} but the pre-filter dropped #{fixture.uid}"
        end
      end
    end
  end

  defp insert_fixture!(partition, spec) do
    Repo.query!(
      """
      INSERT INTO platform.ocsf_devices
        (uid, ip, hostname, metadata, partition, type_id, first_seen_time, last_seen_time)
      VALUES ($1, $2, $3, $4::jsonb, $5, 0, $6, $6)
      """,
      [
        spec.uid,
        spec.ip,
        spec.hostname,
        Jason.encode!(spec.metadata),
        partition,
        ~N[2026-08-13 12:00:00]
      ]
    )

    Map.put(spec, :device, %{
      ip: spec.ip,
      hostname: spec.hostname,
      metadata: spec.metadata
    })
  end

  defp fixture_specs do
    n = System.unique_integer([:positive])
    always = [plain: true, overwrite: true, ignore_retry: true]
    never = [plain: false, overwrite: false, ignore_retry: false]
    retry_only = [plain: false, overwrite: false, ignore_retry: true]

    [
      spec(n, :missing_hostname, "192.0.2.1", nil, %{}, always),
      spec(n, :blank_hostname, "192.0.2.2", "", %{}, always),
      spec(n, :whitespace_hostname, "192.0.2.3", "   ", %{}, always),
      spec(n, :same_ipv4, "192.0.2.4", "192.0.2.4", %{}, always),
      spec(n, :other_ipv4, "192.0.2.5", "198.51.100.8", %{}, always),
      spec(n, :ipv6_hostname, "192.0.2.6", "2001:db8::6", %{}, always),
      spec(n, :cidr_hostname, "192.0.2.7", "192.0.2.99/32", %{}, always),
      spec(n, :zone_hostname, "192.0.2.8", "fe80::1%eth0", %{}, always),
      spec(n, :hex_hostname, "192.0.2.9", "0x7f000001", %{}, always),
      spec(n, :padded_hostname, "192.0.2.10", "  192.0.2.10  ", %{}, always),
      spec(n, :padded_ip, "  192.0.2.11  ", nil, %{}, always),
      spec(n, :cidr_ip, "192.0.2.12/32", nil, %{}, always),
      spec(n, :mixed_case_ipv6, "2001:db8::21", "2001:DB8::21", %{}, always),
      spec(n, :old_lookup, "192.0.2.14", nil, looked_up("2026-08-01T00:00:00Z"), always),
      spec(n, :cutoff_lookup, "192.0.2.15", nil, looked_up("2026-08-12T12:00:00Z"), always),
      spec(
        n,
        :just_inside_window,
        "192.0.2.16",
        nil,
        looked_up("2026-08-12T12:00:01Z"),
        retry_only
      ),
      spec(n, :malformed_lookup, "192.0.2.17", nil, looked_up("not-a-time"), always),
      spec(
        n,
        :minus_zero_lookup,
        "192.0.2.18",
        nil,
        looked_up("2026-08-13T11:30:00-00:00"),
        always
      ),
      spec(
        n,
        :space_separated_old,
        "192.0.2.19",
        nil,
        looked_up("2026-08-01 00:00:00Z"),
        always
      ),
      spec(
        n,
        :space_separated_recent,
        "192.0.2.20",
        nil,
        looked_up("2026-08-13 11:30:00Z"),
        retry_only
      ),
      spec(
        n,
        :offset_old,
        "192.0.2.21",
        nil,
        looked_up("2026-08-01T00:00:00+00:00"),
        always
      ),
      spec(
        n,
        :fractional_old,
        "192.0.2.22",
        nil,
        looked_up("2026-08-01T00:00:00.500000Z"),
        always
      ),
      spec(
        n,
        :fractional_recent,
        "192.0.2.23",
        nil,
        looked_up("2026-08-13T11:30:00.123456Z"),
        retry_only
      ),
      spec(n, :real_hostname, "192.0.2.24", "router.example.com", %{},
        plain: false,
        overwrite: true,
        ignore_retry: false
      ),
      spec(n, :recent_lookup, "192.0.2.25", nil, looked_up("2026-08-13T11:30:00Z"), retry_only),
      spec(n, :no_ip, nil, nil, %{}, never),
      spec(n, :blank_ip, "   ", nil, %{}, never)
    ]
  end

  defp spec(n, label, ip, hostname, metadata, due) do
    %{
      uid: "sr:rdns-elig-#{n}-#{label}",
      label: label,
      ip: ip,
      hostname: hostname,
      metadata: metadata,
      due: Map.new(due)
    }
  end

  defp looked_up(value), do: %{"rdns" => %{"looked_up_at" => value}}
end
