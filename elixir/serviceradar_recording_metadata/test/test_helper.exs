for app <- [:serviceradar_core, :ecto, :postgrex, :membrane_core, :libcluster] do
  {:error, :bad_name} = :code.lib_dir(app)
end

{:ok, _} = Application.ensure_all_started(:serviceradar_recording_metadata)
ExUnit.start()
