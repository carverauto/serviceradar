require 'xcodeproj'

project_path = 'FieldSurvey.xcodeproj'
project = Xcodeproj::Project.open(project_path)

target = project.targets.find { |t| t.name == 'FieldSurvey' }
views_group = project.main_group.find_subpath(File.join('FieldSurvey', 'Views'), true)
file_ref = views_group.new_file('CompositeSurveyView.swift')
target.add_file_references([file_ref])

project.save
