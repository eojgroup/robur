# frozen_string_literal: true

require "json"
require "net/http"
require "time"
require "uri"

class AppStoreConnectHTTP
  API_ROOT = "https://api.appstoreconnect.apple.com"
  MAX_ATTEMPTS = 5
  TRANSIENT_ERRORS = [Net::OpenTimeout, Net::ReadTimeout, EOFError, SocketError,
                      Errno::ECONNRESET, Errno::ETIMEDOUT].freeze

  def initialize(transport: nil, sleeper: nil)
    @transport = transport || method(:perform)
    @sleeper = sleeper || ->(seconds) { sleep(seconds) }
  end

  def request(method, path, token, body: nil)
    uri = URI.join(API_ROOT, path)
    request = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
    request["Authorization"] = "Bearer #{token}"
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body) if body

    attempt = 0
    begin
      attempt += 1
      response = @transport.call(uri, request)
      status = response.code.to_i
      if (status == 429 || status.between?(500, 599)) && attempt < MAX_ATTEMPTS
        pause(path, attempt, "HTTP #{status}", retry_delay(response, attempt))
        retry_request = true
      else
        retry_request = false
      end
    rescue *TRANSIENT_ERRORS => error
      # A timed-out POST may already have been applied; don't replay it blindly.
      raise unless method == :get && attempt < MAX_ATTEMPTS
      pause(path, attempt, error.class.name, 2**attempt)
      retry
    end while retry_request

    return {} if status == 204
    begin
      parsed = JSON.parse(response.body.to_s.empty? ? "{}" : response.body)
    rescue JSON::ParserError
      abort "App Store Connect #{method.to_s.upcase} #{path} failed (HTTP #{status}): non-JSON response"
    end
    return parsed if status.between?(200, 299)

    details = parsed.is_a?(Hash) ? parsed.fetch("errors", parsed).to_json : "Unexpected API response"
    abort "App Store Connect #{method.to_s.upcase} #{path} failed (HTTP #{status}): #{details}"
  end

  private

  def perform(uri, request)
    Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 60) do |http|
      http.max_retries = 0
      http.request(request)
    end
  end

  def retry_delay(response, attempt)
    value = response["Retry-After"].to_s
    delay = if value.match?(/\A\d+\z/)
      value.to_i
    elsif !value.empty?
      begin
        Time.httpdate(value) - Time.now
      rescue ArgumentError
        2**attempt
      end
    else
      2**attempt
    end
    [[delay, 0].max, 60].min
  end

  def pause(path, attempt, reason, seconds)
    warn "App Store Connect #{path}: #{reason}; retry #{attempt}/#{MAX_ATTEMPTS - 1} in #{seconds.round}s"
    @sleeper.call(seconds)
  end
end
