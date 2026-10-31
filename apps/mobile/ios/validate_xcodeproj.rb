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

require "json"
icon_directory = File.join(__dir__, "Resources/Assets.xcassets/AppIcon.appiconset")
JSON.parse(File.read(File.join(icon_directory, "Contents.json"))).fetch("images").each do |image|
  filename = image.fetch("filename")
  png = File.binread(File.join(icon_directory, filename))
  size = (image.fetch("size").to_f * image.fetch("scale").to_f).round
  dimensions = png.byteslice(16, 8).unpack("NN")
  abort "Incorrect icon dimensions: #{filename}" unless dimensions == [size, size]
  abort "App Store icon must be RGB without alpha: #{filename}" unless png.getbyte(25) == 2
end

require "xcodeproj"
%w[RoburApp RoburWatchApp RoburWidgets RoburWatchWidgets].each do |app_name|
  plist = Xcodeproj::Plist.read_from_path(File.join(__dir__, "Sources", app_name, "Info.plist"))
  %w[NSHealthShareUsageDescription NSHealthUpdateUsageDescription].each do |key|
    abort "Missing HealthKit purpose string #{key} in #{app_name}" if plist[key].to_s.strip.empty?
  end
end
project = Xcodeproj::Project.open(project_path)
{
  "Robur" => "com.eojgroup.robur",
  "RoburWatch Watch App" => "com.eojgroup.robur.watchkitapp",
  "Robur Widgets" => "com.eojgroup.robur.widgets",
  "Robur Watch Widgets" => "com.eojgroup.robur.watchkitapp.widgets"
}.each do |name, identifier|
  target = project.targets.find { |candidate| candidate.name == name }
  abort "Missing target #{name}" unless target
  target.build_configurations.each do |config|
    abort "Wrong bundle ID on #{name}" unless config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] == identifier
    if name == "Robur"
      families = config.build_settings["TARGETED_DEVICE_FAMILY"].to_s.split(",").map(&:strip)
      abort "Universal iPhone/iPad device families must remain enabled" unless families.sort == %w[1 2]
    end
  end
  resources = target.resources_build_phase.files_references.map { |file| File.basename(file.path.to_s) }
  abort "Privacy manifest is not bundled in #{name}" unless resources.include?("PrivacyInfo.xcprivacy")
end
app = project.targets.find { |target| target.name == "Robur" }
abort "Watch companion is not embedded" unless app.copy_files_build_phases.any? { |phase| phase.files_references.any? { |file| file == project.targets.find { |target| target.name == "RoburWatch Watch App" }.product_reference } }
{
  "Robur" => "Robur Widgets",
  "RoburWatch Watch App" => "Robur Watch Widgets"
}.each do |parent_name, widget_name|
  parent = project.targets.find { |target| target.name == parent_name }
  widget = project.targets.find { |target| target.name == widget_name }
  abort "#{widget_name} is not embedded in #{parent_name}" unless parent.copy_files_build_phases.any? { |phase| phase.files_references.include?(widget.product_reference) }
end
puts "Robur Apple project contracts verified: universal app, Watch companion, both widget extensions and privacy manifests."
