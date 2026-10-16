# Keep compiled helper beams so the isolated server VMs use the same declared
# sources as the driver. No runtime script generation or application test hooks.
modules =
  Enum.flat_map(~w(fixture meter replica client), fn file ->
    Code.compile_file(Path.join(__DIR__, file <> ".exs"))
  end)

Application.put_env(:serviceradar_web_ng, :topology_scale_modules, modules)
{:ok, _} = Application.ensure_all_started(:gun)
