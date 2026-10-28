# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../app_store_connect_http"

class AppStoreConnectHTTPTest < Minitest::Test
  Response = Struct.new(:code, :body, :headers) do
    def [](key)
      (headers || {})[key]
    end
  end

  def client_with(*responses)
    @calls = []
    @delays = []
    AppStoreConnectHTTP.new(
      transport: lambda { |uri, request|
        @calls << [uri, request]
        response = responses.shift or raise "Unexpected extra request"
        raise response if response.is_a?(Exception)
        response
      },
      sleeper: ->(seconds) { @delays << seconds }
    )
  end

  def test_recovers_from_apple_500_even_when_body_is_not_json
    client = client_with(Response.new("500", "<html>Server error</html>"),
                         Response.new("200", '{"data":[]}'))
    assert_equal({ "data" => [] }, client.request(:get, "/v1/apps/1/betaGroups", "test-token"))
    assert_equal 2, @calls.length
    assert_equal [2], @delays
    assert_equal "Bearer test-token", @calls.last[1]["Authorization"]
  end

  def test_honors_rate_limit_delay_and_caps_it
    client = client_with(Response.new("429", "", { "Retry-After" => "3600" }), Response.new("204", ""))
    assert_equal({}, client.request(:get, "/v1/builds", "test-token"))
    assert_equal [60], @delays
  end

  def test_retries_have_a_finite_budget
    client = client_with(*Array.new(5) { Response.new("503", '{"errors":[]}') })
    error = assert_raises(SystemExit) { client.request(:get, "/v1/builds", "test-token") }
    refute error.success?
    assert_equal 5, @calls.length
    assert_equal [2, 4, 8, 16], @delays
  end

  def test_invalid_credentials_are_not_retried
    client = client_with(Response.new("401", '{"errors":[{"code":"NOT_AUTHORIZED"}]}'))
    assert_raises(SystemExit) { client.request(:get, "/v1/builds", "test-token") }
    assert_equal 1, @calls.length
    assert_empty @delays
  end

  def test_transient_get_transport_error_recovers
    client = client_with(Net::ReadTimeout.new, Response.new("200", '{"data":{}}'))
    assert_equal({ "data" => {} }, client.request(:get, "/v1/builds", "test-token"))
    assert_equal [2], @delays
  end

  def test_ambiguous_post_timeout_is_not_replayed
    client = client_with(Net::ReadTimeout.new)
    assert_raises(Net::ReadTimeout) do
      client.request(:post, "/v1/builds/1/relationships/betaGroups", "test-token", body: { data: [] })
    end
    assert_equal 1, @calls.length
    assert_empty @delays
  end

  def test_relationship_assignment_recovers_from_server_failure
    client = client_with(Response.new("502", "Bad gateway"), Response.new("204", ""))
    payload = { data: [{ type: "betaGroups", id: "group-1" }] }
    assert_equal({}, client.request(:post, "/v1/builds/1/relationships/betaGroups", "test-token", body: payload))
    assert_equal JSON.generate(payload), @calls.last[1].body
    assert_equal [2], @delays
  end
end
