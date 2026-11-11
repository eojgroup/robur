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

def validate_universal_capabilities(plist, label)
  # Apple's healthkit device filter still limits installation to iPhone,
  # even though HealthKit itself is available on iPadOS 17 and later.
  # Keep the HealthKit entitlement and check availability at runtime instead.
  capabilities = plist.fetch("UIRequiredDeviceCapabilities", [])
  abort "#{label}: remove the healthkit required-device filter to allow iPad installation" if capabilities.include?("healthkit")
end

%w[RoburApp RoburWatchApp RoburWidgets RoburWatchWidgets].each do |app_name|
  plist = Xcodeproj::Plist.read_from_path(File.join(__dir__, "Sources", app_name, "Info.plist"))
  validate_universal_capabilities(plist, app_name) if %w[RoburApp RoburWidgets].include?(app_name)
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
    if ["Robur", "Robur Widgets"].include?(name)
      families = config.build_settings["TARGETED_DEVICE_FAMILY"].to_s.split(",").map(&:strip)
      abort "Universal iPhone/iPad device families must remain enabled" unless families.sort == %w[1 2]
    end
  end
  resources = target.resources_build_phase.files_references.map { |file| File.basename(file.path.to_s) }
  abort "Privacy manifest is not bundled in #{name}" unless resources.include?("PrivacyInfo.xcprivacy")
  abort "Metric palette is not bundled in #{name}" unless resources.include?("metric-colors.json")
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

# CI passes the compiled app's Info.plist after archiving, so merged build
# settings cannot silently reintroduce an iPhone-only distribution filter.
if ARGV[0]
  # Archives contain binary plists. xcodeproj's conflict scan treats their
  # bytes as UTF-8 on some Ruby versions, so let Apple's tool decode them.
  require "open3"
  plist_json, plist_error, plist_status = Open3.capture3("/usr/bin/plutil", "-convert", "json", "-o", "-", ARGV[0])
  abort "Cannot read archived app plist: #{plist_error}" unless plist_status.success?
  archived_plist = JSON.parse(plist_json)
  validate_universal_capabilities(archived_plist, "Archived Robur app")
  abort "Archived app must support both iPhone and iPad" unless Array(archived_plist["UIDeviceFamily"]).sort == [1, 2]
  puts "Archived app supports iPhone and iPad without a HealthKit installation filter."
end
puts "Robur Apple project contracts verified: universal app, Watch companion, both widget extensions and privacy manifests."
