# frozen_string_literal: true

require "uri"

# Upload validation can fail before /builds exposes a record. Inspect the upload
# resource too, rather than reporting every rejected upload as a processing timeout.
class TestFlightBuildWaiter
  class ProcessingError < StandardError; end

  def initialize(requester:, sleeper: ->(seconds) { sleep(seconds) }, logger: ->(message) { warn(message) })
    @requester, @sleeper, @logger = requester, sleeper, logger
  end

  def wait(app_id:, build_number:, attempts: 80, interval: 30)
    encoded = URI.encode_www_form_component(build_number)
    attempts.times do |attempt|
      builds = @requester.call("/v1/builds?filter%5Bapp%5D=#{app_id}&filter%5Bversion%5D=#{encoded}&sort=-uploadedDate&limit=1").fetch("data", [])
      build = builds.find { |item| item.dig("attributes", "version").to_s == build_number }
      state = build&.dig("attributes", "processingState")
      return build if state == "VALID"
      if %w[FAILED INVALID].include?(state)
        raise ProcessingError, "Uploaded build #{build_number} entered processing state #{state}"
      end

      uploads = @requester.call("/v1/apps/#{app_id}/buildUploads?filter%5BcfBundleVersion%5D=#{encoded}&include=build&sort=-uploadedDate&limit=1")
      upload = uploads.fetch("data", []).find { |item| item.dig("attributes", "cfBundleVersion").to_s == build_number }
      details = upload&.dig("attributes", "state")
      upload_state = details.is_a?(Hash) ? details["state"] : details
      if upload_state == "FAILED"
        errors = details.is_a?(Hash) ? details.fetch("errors", []) : []
        message = errors.map { |item| [item["code"], item["description"], item["message"]].compact.join(": ") }.join("; ")
        raise ProcessingError, "Apple rejected build #{build_number}: #{message.empty? ? 'review Build Uploads in App Store Connect for validation errors' : message}"
      end
      linked_id = upload&.dig("relationships", "build", "data", "id")
      linked = uploads.fetch("included", []).find { |item| item["type"] == "builds" && item["id"] == linked_id && item.dig("attributes", "version").to_s == build_number }
      return linked if linked&.dig("attributes", "processingState") == "VALID"

      @logger.call("Waiting for TestFlight build #{build_number} (attempt #{attempt + 1}/#{attempts}, build #{state || 'not visible'}, upload #{upload_state || 'not visible'})")
      @sleeper.call(interval) if attempt + 1 < attempts
    end
    raise ProcessingError, "Build #{build_number} is not available after #{(attempts - 1) * interval / 60} minutes. Check App Store Connect → Build Uploads before uploading again; an accepted upload is not a completed TestFlight release."
  end
end
