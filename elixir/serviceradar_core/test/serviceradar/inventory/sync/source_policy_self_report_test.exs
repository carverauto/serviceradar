defmodule ServiceRadar.Inventory.Sync.SourcePolicySelfReportTest do
  @moduledoc """
  Locks the three properties the agent self-report source depends on.

  `observer_agent_source?/1` is a POSITIVE list, so a brand-new source is
  first-party by default and every assertion here passes the moment the source
  string exists. That is exactly why the tests are worth having: nothing would
  fail loudly if someone later added `agent-self-report` to
  `enrichment_only_source?/1`, which is a disjunct of `observer_agent_source?/1`
  and would silently strip both its ability to anchor an `agent_id` AND its
  ability to create a device.

  See `openspec/changes/add-agent-self-report-device-identity` tasks 2.1-2.3.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Sync.SourcePolicy

  @agent_id "agent-k8s-cp3-worker1"

  defp update(source, metadata \\ %{}) do
    %{source: source, metadata: metadata}
  end

  defp ids(agent_id \\ @agent_id), do: %{agent_id: agent_id}

  describe "agent_self_report_source?/1" do
    test "recognises the canonical source string, case-insensitively" do
      assert SourcePolicy.agent_self_report_source() == "agent-self-report"
      assert SourcePolicy.agent_self_report_source?(update("agent-self-report"))
      assert SourcePolicy.agent_self_report_source?(update("Agent-Self-Report"))
    end

    test "does not match neighbouring agent-ish sources" do
      # `agent` and `sysmon` already exist and are NOT this source. Matching them
      # would hand an observer-minted update the right to anchor an agent_id.
      for other <- ["agent", "sysmon", "sweep", "mapper", "netprobe-census", ""] do
        refute SourcePolicy.agent_self_report_source?(update(other)),
               "#{inspect(other)} must not be treated as a self-report"
      end
    end

    test "tolerates a non-map and a nil source" do
      refute SourcePolicy.agent_self_report_source?(nil)
      refute SourcePolicy.agent_self_report_source?(update(nil))
    end
  end

  describe "task 2.1 — the self-report is first-party" do
    test "is not an observer, so its agent_id is admitted as an identifier" do
      self_report = update(SourcePolicy.agent_self_report_source())

      refute SourcePolicy.observer_agent_source?(self_report)
      assert SourcePolicy.include_agent_identifier?(self_report, ids())
    end

    test "a blank agent_id is still refused" do
      # Being first-party buys the right to anchor a REAL agent_id, not to
      # register an empty one.
      self_report = update(SourcePolicy.agent_self_report_source())

      refute SourcePolicy.include_agent_identifier?(self_report, ids(""))
      refute SourcePolicy.include_agent_identifier?(self_report, ids(nil))
    end
  end

  describe "task 2.3 — the self-report may create a device" do
    test "is not enrichment-only" do
      # enrichment_only_source?/1 is the rule that forbids creation. If this ever
      # returns true the source can describe a device but never mint one, and the
      # duplicate it exists to prevent comes straight back.
      refute SourcePolicy.enrichment_only_source?(update(SourcePolicy.agent_self_report_source()))
    end
  end

  describe "task 2.2 — no existing source changes classification" do
    test "sources that were observers stay observers" do
      for source <- [
            "mapper",
            "sweep",
            "netprobe-census",
            "netprobe-mdns",
            "passive-mdns",
            "passive-netprobe",
            "armis",
            "snmp",
            "snmp-metrics",
            "snmp_metrics"
          ] do
        assert SourcePolicy.observer_agent_source?(update(source)),
               "#{source} must remain an observer"

        refute SourcePolicy.include_agent_identifier?(update(source), ids()),
               "#{source} must not anchor an agent_id"
      end
    end

    test "sources that were enrichment-only stay enrichment-only" do
      for source <- ["netprobe-mdns", "passive-mdns", "passive-netprobe"] do
        assert SourcePolicy.enrichment_only_source?(update(source)),
               "#{source} must remain enrichment-only"
      end

      for identity_source <- [
            "netprobe_mdns",
            "netprobe_fingerprint",
            "netprobe_dpi",
            "netprobe_process"
          ] do
        assert SourcePolicy.enrichment_only_source?(
                 update("anything", %{"identity_source" => identity_source})
               ),
               "identity_source #{identity_source} must remain enrichment-only"
      end
    end

    test "the self-report does not become enrichment-only via identity_source" do
      # observer_agent_source?/1 reaches enrichment_only_source?/1, which also
      # keys on metadata identity_source. A self-report carrying an enrichment
      # identity_source would be demoted -- assert the plain case is unaffected.
      self_report =
        update(SourcePolicy.agent_self_report_source(), %{
          "identity_source" => "agent_self_report"
        })

      refute SourcePolicy.enrichment_only_source?(self_report)
      refute SourcePolicy.observer_agent_source?(self_report)
      assert SourcePolicy.include_agent_identifier?(self_report, ids())
    end
  end
end
