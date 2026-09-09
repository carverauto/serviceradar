defmodule ServiceRadarWebNG.Plugins.NativeAddonSyncDecisionTest do
  @moduledoc """
  DB-free regression tests for the add-on import -> approval policy
  (GitHub #335, #336, #337).

  Covers the pure decision layer of `NativeAddonSync`:

  * `import_decision/3` — a same-version first-party rebuild must take the
    replace path (Import All behaves like the per-row Replace button) instead
    of failing the whole import with a source conflict, while rows owned by
    another source type must still conflict (#335).
  * `auto_approve_eligible?/3` — a staged first-party build is auto-approved
    only when an enabled tracking profile opted the add-on into automatic
    updates AND the build asks for no capability outside the already-approved
    ceiling; any expansion stays staged for human review (#337).
  * `summary/2` — imported, skipped, and failed results are counted so the
    Import All flash message stays honest (#335).
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.NativeAddonArtifactMirror
  alias ServiceRadarWebNG.Plugins.NativeAddonSync

  @moduletag :db_free

  defp package(overrides) do
    struct!(
      AddonPackage,
      Map.merge(
        %{
          addon_id: "sample-addon",
          version: "1.0.0",
          name: "Sample Addon",
          source_type: :first_party,
          source_oci_ref: "registry.example.test/sample-addon:v1.0.0",
          source_oci_digest: "sha256:" <> String.duplicate("a", 64),
          source_metadata: %{"bundle_digest" => "sha256:" <> String.duplicate("b", 64)},
          verification_status: "verified",
          verification_error: nil,
          status: :staged,
          capabilities: ["submit_result"],
          approved_capabilities: [],
          artifacts: %{}
        },
        overrides
      )
    )
  end

  defp addon(overrides) do
    Map.merge(
      %{
        addon_id: "sample-addon",
        version: "1.0.0",
        release_tag: "v1.0.0",
        oci_ref: "registry.example.test/sample-addon:v1.0.0",
        oci_digest: "sha256:" <> String.duplicate("a", 64),
        bundle_digest: "sha256:" <> String.duplicate("b", 64),
        artifacts: []
      },
      overrides
    )
  end

  defp reusable_pair do
    sha = String.duplicate("c", 64)
    signature = String.duplicate("d", 128)
    canonical = "sha256:" <> (:sha256 |> :crypto.hash(signature <> "\n") |> Base.encode16(case: :lower))
    object_key = NativeAddonArtifactMirror.object_key("sample-addon", "1.0.0", "linux", "amd64", sha)

    persisted = %{
      "linux/amd64" => %{
        "object_key" => object_key,
        "sha256" => sha,
        "signature" => signature,
        "signature_digest" => canonical
      }
    }

    declared = [
      %{
        "os" => "linux",
        "arch" => "amd64",
        "tarball_sha256" => sha,
        "tarball_digest" => "sha256:" <> sha,
        "signature_digest" => canonical
      }
    ]

    {package(%{artifacts: persisted}), addon(%{artifacts: declared})}
  end

  describe "import_decision/3" do
    test "no existing row means a fresh import" do
      assert NativeAddonSync.import_decision(nil, addon(%{}), []) == :import_new
    end

    test "a row owned by another source type still conflicts (#335 guardrail)" do
      for source_type <- [:upload, :github] do
        existing = package(%{source_type: source_type, source_oci_ref: nil, source_oci_digest: nil})

        assert NativeAddonSync.import_decision(existing, addon(%{}), []) ==
                 {:conflict, :source_type_owned}
      end
    end

    test "an identical verified build reuses instead of replacing" do
      {existing, discovered} = reusable_pair()

      assert NativeAddonSync.import_decision(existing, discovered, []) == :reuse
    end

    test "a same-version rebuild with complete provenance replaces, even without replace: true (#335)" do
      existing = package(%{})

      discovered =
        addon(%{
          oci_ref: "registry.example.test/sample-addon:v1.0.1",
          oci_digest: "sha256:" <> String.duplicate("e", 64),
          bundle_digest: "sha256:" <> String.duplicate("f", 64)
        })

      assert NativeAddonSync.import_decision(existing, discovered, []) == :replace
      assert NativeAddonSync.import_decision(existing, discovered, replace: true) == :replace
    end

    test "an unverified seeder placeholder without source identity flows through plain import (#4039)" do
      existing =
        package(%{
          verification_status: "seeded",
          source_oci_ref: nil,
          source_oci_digest: nil
        })

      # Empty provenance can never disagree, so the core reconciler heals the
      # row downstream without an explicit replace.
      assert NativeAddonSync.import_decision(existing, addon(%{}), []) == :import
    end

    test "a row with partial provenance is not silently overwritten" do
      existing =
        package(%{
          source_oci_ref: nil,
          source_oci_digest: "sha256:" <> String.duplicate("e", 64)
        })

      # A nil ref next to a digest that matches nothing is corruption or
      # tampering, not a rebuild: the core conflict guard still fires after
      # verification instead of overwriting it.
      assert NativeAddonSync.import_decision(existing, addon(%{}), []) == :import
      assert NativeAddonSync.import_decision(existing, addon(%{}), replace: true) == :replace
    end

    test "an approved row rebuild is still a replace decision (review is restaged downstream)" do
      existing = package(%{status: :approved, approved_capabilities: ["submit_result"]})

      discovered =
        addon(%{bundle_digest: "sha256:" <> String.duplicate("f", 64)})

      assert NativeAddonSync.import_decision(existing, discovered, []) == :replace
    end
  end

  describe "auto_approve_eligible?/3" do
    test "tracking profile plus no capability expansion approves (#337)" do
      ceiling = MapSet.new(["submit_result"])

      assert NativeAddonSync.auto_approve_eligible?(["submit_result"], true, ceiling)
    end

    test "fewer capabilities than approved still approves" do
      ceiling = MapSet.new(["submit_result", "extra"])

      assert NativeAddonSync.auto_approve_eligible?(["submit_result"], true, ceiling)
      assert NativeAddonSync.auto_approve_eligible?([], true, ceiling)
    end

    test "capability expansion stays staged for human review" do
      ceiling = MapSet.new(["submit_result"])

      refute NativeAddonSync.auto_approve_eligible?(["submit_result", "raw_exec"], true, ceiling)
    end

    test "no tracking profile means no auto-approval even when capabilities match" do
      ceiling = MapSet.new(["submit_result"])

      refute NativeAddonSync.auto_approve_eligible?(["submit_result"], false, ceiling)
    end

    test "an empty ceiling only admits a capability-free build" do
      assert NativeAddonSync.auto_approve_eligible?([], true, MapSet.new())
      refute NativeAddonSync.auto_approve_eligible?(["submit_result"], true, MapSet.new())
    end

    test "nil capabilities never approve" do
      refute NativeAddonSync.auto_approve_eligible?(nil, true, MapSet.new(["submit_result"]))
    end
  end

  describe "summary/2" do
    test "counts imported, skipped, and failed results" do
      discovered = [addon(%{}), addon(%{version: "2.0.0"}), addon(%{version: "3.0.0"})]

      results = [
        {Enum.at(discovered, 0), {:imported, %{id: "new"}}},
        {Enum.at(discovered, 1), {:skipped, %{id: "current"}}},
        {Enum.at(discovered, 2), {:error, :boom}}
      ]

      summary = NativeAddonSync.summary(discovered, results)

      assert summary.discovered == 3
      assert summary.import_ready == 3
      assert summary.imported == 1
      assert summary.skipped == 1
      assert [%{addon_id: "sample-addon", version: "3.0.0", error: :boom}] = summary.failed
    end
  end
end
