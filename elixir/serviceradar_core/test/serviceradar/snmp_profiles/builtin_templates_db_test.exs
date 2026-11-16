defmodule ServiceRadar.SNMPProfiles.BuiltinTemplatesDbTest do
  @moduledoc """
  The built-in SNMP OID templates are product data, written under fixed ids so
  the default SNMP profile can reference them on every install.
  """
  use ServiceRadar.DataCase, async: false

  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.SNMPProfiles.BuiltinTemplates
  alias ServiceRadar.SNMPProfiles.SNMPOIDTemplate

  require Ash.Query

  @moduletag :integration

  @admin %{
    id: "snmp-builtin-template-admin",
    role: :admin,
    permissions: MapSet.new(["settings.snmp_profiles.manage"])
  }

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  test "seeding writes each standard template once, under its fixed id, never over an operator's" do
    system = SystemActor.system(:test)
    [uptime | others] = BuiltinTemplates.seeded()

    operator =
      SNMPOIDTemplate
      |> Ash.Changeset.for_create(
        :create,
        %{name: uptime.name, vendor: uptime.vendor, oids: [%{oid: ".1.3.6.1.2.1.1.5.0"}]},
        actor: @admin
      )
      |> Ash.create!(actor: @admin)

    assert {:ok, created} = BuiltinTemplates.seed(system)
    assert created == length(others)
    assert {:ok, 0} = BuiltinTemplates.seed(system)

    assert %{is_builtin: false, oids: [%{"oid" => ".1.3.6.1.2.1.1.5.0"}]} =
             Ash.get!(SNMPOIDTemplate, operator.id, actor: system)

    ids = Enum.map(others, & &1.id)

    rows =
      SNMPOIDTemplate
      |> Ash.Query.filter(id in ^ids)
      |> Ash.read!(actor: system)

    assert Enum.sort(Enum.map(rows, & &1.id)) == Enum.sort(ids)

    for row <- rows, oid <- row.oids do
      assert row.is_builtin

      # A profile applies a template to devices whose interface indexes it does
      # not know, so only a scalar instance can be read with a GET.
      expected_mode = if String.ends_with?(oid["oid"], ".0"), do: nil, else: "walk"
      assert oid["mode"] == expected_mode, "#{row.name}: #{oid["name"]}"
    end
  end

  test "only the system actor writes a built-in template" do
    [template | _] = BuiltinTemplates.seeded()
    {id, attrs} = Map.pop!(template, :id)

    assert {:error, %Forbidden{}} =
             SNMPOIDTemplate
             |> Ash.Changeset.for_create(:seed_builtin, Map.put(attrs, :builtin_id, id),
               actor: @admin
             )
             |> Ash.create(actor: @admin)
  end
end
