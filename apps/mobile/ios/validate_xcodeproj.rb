#!/usr/bin/env ruby
# frozen_string_literal: true

required_paths = [
  "project.yml",
  "VERSION",
  "Resources/PrivacyInfo.xcprivacy",
  "Sources/RoburApp/Info.plist",
  "Sources/RoburApp/Robur.entitlements",
  "Sources/RoburShared/HealthKitClient.swift",
  "Sources/RoburWatchApp/Info.plist",
  "Sources/RoburWatchApp/RoburWatch.entitlements",
  "Resources/Assets.xcassets/AppIcon.appiconset/Contents.json"
]

missing = required_paths.reject { |path| File.exist?(File.join(__dir__, path)) }

unless missing.empty?
  warn "Missing required Apple project files:"
  missing.each { |path| warn "  - #{path}" }
  exit 1
end

project_path = File.join(__dir__, "Robur.xcodeproj")
unless Dir.exist?(project_path)
  warn "Robur.xcodeproj is missing. Run ruby generate_xcodeproj.rb first."
  exit 1
end

require "xcodeproj"
project = Xcodeproj::Project.open(project_path)
{
  "Robur" => "com.eojgroup.robur",
  "RoburWatch Watch App" => "com.eojgroup.robur.watchkitapp"
}.each do |name, identifier|
  target = project.targets.find { |candidate| candidate.name == name }
  abort "Missing target #{name}" unless target
  target.build_configurations.each do |config|
    abort "Wrong bundle ID on #{name}" unless config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] == identifier
  end
  resources = target.resources_build_phase.files_references.map { |file| File.basename(file.path.to_s) }
  abort "Privacy manifest is not bundled in #{name}" unless resources.include?("PrivacyInfo.xcprivacy")
end
app = project.targets.find { |target| target.name == "Robur" }
abort "Watch companion is not embedded" unless app.copy_files_build_phases.any? { |phase| phase.files_references.any? { |file| file == project.targets.find { |target| target.name == "RoburWatch Watch App" }.product_reference } }
puts "Robur Apple project contracts verified, including both privacy manifests and embedded Watch app."
