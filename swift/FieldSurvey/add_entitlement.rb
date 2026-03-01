require 'xcodeproj'

project_path = 'FieldSurvey.xcodeproj'
project = Xcodeproj::Project.open(project_path)

project.targets.each do |target|
  if target.name == 'FieldSurvey'
    target.build_configurations.each do |config|
      config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'FieldSurvey/FieldSurvey.entitlements'
    end
  end
end

project.save
