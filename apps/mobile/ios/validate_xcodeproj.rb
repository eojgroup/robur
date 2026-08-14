#!/usr/bin/env ruby
# frozen_string_literal: true

required_paths = [
  "project.yml",
  "VERSION",
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

puts "Robur Apple project contract looks complete."
