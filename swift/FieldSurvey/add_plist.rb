require 'xcodeproj'

project_path = 'FieldSurvey.xcodeproj'
project = Xcodeproj::Project.open(project_path)

project.targets.each do |target|
  if target.name == 'FieldSurvey'
    target.build_configurations.each do |config|
      config.build_settings['INFOPLIST_KEY_NSCameraUsageDescription'] = "Camera access is required for ARKit and LiDAR spatial mapping."
      config.build_settings['INFOPLIST_KEY_NSLocalNetworkUsageDescription'] = "Local network access is required to perform high-fidelity network discovery."
      config.build_settings['INFOPLIST_KEY_NSLocationWhenInUseUsageDescription'] = "Location access is required for Wi-Fi and Bluetooth positioning mapping."
      config.build_settings['INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription'] = "Bluetooth access is required for BLE beacon trilateration."
    end
  end
end

project.save
