defmodule ServiceRadar.EventWriter.IngestAttributionTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.IngestAttribution

  @empty %{ingest_identity: "", ingest_agent_id: "", ingest_partition: ""}

  describe "from_headers/1" do
    test "maps the Sr-* header triple to attribution columns" do
      headers = [
        {"Sr-Ingest-Identity", "spiffe://serviceradar/gateway/gw-1"},
        {"Sr-Agent-Id", "agent-42"},
        {"Sr-Partition", "site-a"}
      ]

      assert IngestAttribution.from_headers(headers) == %{
               ingest_identity: "spiffe://serviceradar/gateway/gw-1",
               ingest_agent_id: "agent-42",
               ingest_partition: "site-a"
             }
    end

    test "matches header keys case-insensitively" do
      headers = [
        {"sr-ingest-identity", "id"},
        {"SR-AGENT-ID", "agent"},
        {"sR-pArTiTiOn", "part"}
      ]

      assert IngestAttribution.from_headers(headers) == %{
               ingest_identity: "id",
               ingest_agent_id: "agent",
               ingest_partition: "part"
             }
    end

    test "accepts a map carrier" do
      headers = %{
        "Sr-Ingest-Identity" => "id",
        "Sr-Agent-Id" => "agent",
        "Sr-Partition" => "part"
      }

      assert IngestAttribution.from_headers(headers) == %{
               ingest_identity: "id",
               ingest_agent_id: "agent",
               ingest_partition: "part"
             }
    end

    test "takes the first value of multi-value headers" do
      headers = [{"Sr-Agent-Id", ["agent-1", "agent-2"]}]

      assert IngestAttribution.from_headers(headers).ingest_agent_id == "agent-1"
    end

    test "absent headers map to empty strings" do
      assert IngestAttribution.from_headers([]) == @empty
      assert IngestAttribution.from_headers(%{}) == @empty
      assert IngestAttribution.from_headers(nil) == @empty
      assert IngestAttribution.from_headers([{"Nats-Msg-Id", "abc"}]) == @empty
    end

    test "partial headers default the missing columns to empty strings" do
      headers = [{"Sr-Agent-Id", "agent-42"}]

      assert IngestAttribution.from_headers(headers) == %{
               ingest_identity: "",
               ingest_agent_id: "agent-42",
               ingest_partition: ""
             }
    end

    test "unusable carriers and values map to empty strings" do
      assert IngestAttribution.from_headers("not-headers") == @empty
      assert IngestAttribution.from_headers([{"Sr-Agent-Id", nil}, :weird]) == @empty
    end
  end

  describe "from_metadata/1" do
    test "reads headers from Broadway message metadata" do
      metadata = %{
        subject: "events.poller",
        headers: [{"Sr-Partition", "site-b"}]
      }

      assert IngestAttribution.from_metadata(metadata).ingest_partition == "site-b"
    end

    test "metadata without headers yields the empty triple" do
      assert IngestAttribution.from_metadata(%{subject: "events.poller"}) == @empty
      assert IngestAttribution.from_metadata(nil) == @empty
    end
  end

  describe "attach/2" do
    test "merges the triple into a single row" do
      attribution = %{@empty | ingest_agent_id: "agent-1"}

      assert IngestAttribution.attach(%{name: "span"}, attribution) == %{
               name: "span",
               ingest_identity: "",
               ingest_agent_id: "agent-1",
               ingest_partition: ""
             }
    end

    test "merges the triple into every row of a list" do
      attribution = %{@empty | ingest_partition: "site-c"}

      assert [%{ingest_partition: "site-c"}, %{ingest_partition: "site-c"}] =
               IngestAttribution.attach([%{a: 1}, %{b: 2}], attribution)
    end

    test "passes nil through" do
      assert IngestAttribution.attach(nil, @empty) == nil
    end
  end
end
