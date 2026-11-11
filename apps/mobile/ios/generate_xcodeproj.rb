#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
# One semantic palette powers native charts and the web analytics dashboard.
FileUtils.cp(File.expand_path("../../../packages/core/src/metric-colors.json", __dir__),
  File.join(__dir__, "Resources", "metric-colors.json"))

version_file = File.join(__dir__, "VERSION")

if File.exist?(version_file)
  File.readlines(version_file, chomp: true).each do |line|
    key, value = line.split("=", 2)
    next if key.nil? || value.nil? || ENV.key?(key)

    ENV[key] = value
  end
end

ENV["APPLE_TEAM_ID"] ||= ENV["DEVELOPMENT_TEAM"] || "REPLACE_IN_XCODE"

exec("xcodegen", "generate", "--spec", "project.yml")
