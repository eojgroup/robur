# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../testflight_build_waiter"

class TestFlightBuildWaiterTest < Minitest::Test
  def waiter(*responses)
    @paths, @sleeps = [], []
    TestFlightBuildWaiter.new(requester: ->(path) { @paths << path; responses.shift || raise("Unexpected extra API request") },
      sleeper: ->(seconds) { @sleeps << seconds }, logger: ->(_message) {})
  end

  def build(state = "VALID", version = "1000.42.1")
    { "id" => "b1", "type" => "builds", "attributes" => { "version" => version, "processingState" => state } }
  end

  def test_already_valid_build_needs_no_upload_lookup
    client = waiter({ "data" => [build] })
    assert_equal "b1", client.wait(app_id: "app", build_number: "1000.42.1")["id"]
    assert_empty @sleeps
    assert_equal 1, @paths.length
  end

  def test_rejected_upload_reports_apple_validation_error_before_build_exists
    client = waiter({ "data" => [] }, { "data" => [{ "attributes" => { "cfBundleVersion" => "1000.42.1",
      "state" => { "state" => "FAILED", "errors" => [{ "code" => "ITMS-ERROR", "description" => "Missing purpose string" }] } } }] })
    error = assert_raises(TestFlightBuildWaiter::ProcessingError) { client.wait(app_id: "app", build_number: "1000.42.1") }
    assert_includes error.message, "ITMS-ERROR: Missing purpose string"
    assert_empty @sleeps
  end

  def test_waits_for_processing_and_uses_linked_valid_build
    processing = { "attributes" => { "cfBundleVersion" => "1000.42.1", "state" => { "state" => "PROCESSING" } } }
    complete = { "attributes" => { "cfBundleVersion" => "1000.42.1", "state" => { "state" => "COMPLETE" } },
      "relationships" => { "build" => { "data" => { "id" => "b1" } } } }
    client = waiter({ "data" => [] }, { "data" => [processing] }, { "data" => [] }, { "data" => [complete], "included" => [build] })
    assert_equal "b1", client.wait(app_id: "app", build_number: "1000.42.1")["id"]
    assert_equal [30], @sleeps
  end

  def test_does_not_accept_unrelated_build_and_has_finite_wait
    client = waiter({ "data" => [build("VALID", "other")] }, { "data" => [] })
    error = assert_raises(TestFlightBuildWaiter::ProcessingError) { client.wait(app_id: "app", build_number: "1000.42.1", attempts: 1) }
    assert_includes error.message, "Check App Store Connect"
    assert_empty @sleeps
  end
end
