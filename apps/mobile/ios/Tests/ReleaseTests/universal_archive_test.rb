# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "xcodeproj"

class UniversalArchiveTest < Minitest::Test
  def validate_archive(plist, format: "binary1")
    Dir.mktmpdir("robur-archive-test") do |directory|
      path = File.join(directory, "Info.plist")
      Xcodeproj::Plist.write_to_path(plist, path)
      output, status = Open3.capture2e("/usr/bin/plutil", "-convert", format, path)
      assert status.success?, output
      assert_equal "bplist00", File.binread(path, 8) if format == "binary1"
      validator = File.expand_path("../../validate_xcodeproj.rb", __dir__)
      Open3.capture2e(RbConfig.ruby, validator, path)
    end
  end

  def test_accepts_universal_binary_and_xml_archives
    %w[binary1 xml1].each do |format|
      output, status = validate_archive({ "UIDeviceFamily" => [1, 2], "CFBundleDisplayName" => "Robur Health" }, format: format)
      assert status.success?, output
      assert_includes output, "Archived app supports iPhone and iPad"
    end
  end

  def test_rejects_iphone_only_binary_archive
    output, status = validate_archive({ "UIDeviceFamily" => [1] })
    refute status.success?
    assert_includes output, "Archived app must support both iPhone and iPad"
  end

  def test_rejects_healthkit_filter_in_both_supported_forms
    [["healthkit"], { "healthkit" => true }].each do |capabilities|
      output, status = validate_archive({ "UIDeviceFamily" => [1, 2], "UIRequiredDeviceCapabilities" => capabilities })
      refute status.success?
      assert_includes output, "remove the healthkit required-device filter"
    end
  end
end
