require 'xcodeproj'

project_path = 'FieldSurvey.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'FieldSurvey' }

# Add package reference
package_ref = project.root_object.package_references.find { |pr| pr.repositoryURL.include?('RPerfClient') }
unless package_ref
  package_ref = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  package_ref.repositoryURL = "file:///Users/mfreeman/src/serviceradar/swift/RPerfClient"
  package_ref.requirement = {
    'kind' => 'branch',
    'branch' => 'main'
  }
  project.root_object.package_references << package_ref
end

# Add product dependency
product_dep = target.package_product_dependencies.find { |pd| pd.product_name == 'RPerfClient' }
unless product_dep
  product_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product_dep.package = package_ref
  product_dep.product_name = 'RPerfClient'
  target.package_product_dependencies << product_dep
end

# Add to Frameworks build phase
frameworks_phase = target.frameworks_build_phase
build_file = frameworks_phase.files.find { |f| f.product_ref == product_dep }
unless build_file
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = product_dep
  frameworks_phase.files << build_file
end

project.save