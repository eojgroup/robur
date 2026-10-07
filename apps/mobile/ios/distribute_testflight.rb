#!/usr/bin/env ruby
# frozen_string_literal: true

# Waits for a just-uploaded build and assigns it to the preconfigured internal
# TestFlight group. The exact group name is a protected GitHub environment
# variable so distribution cannot silently omit testers.

require "base64"
require "json"
require "net/http"
require "openssl"
require "uri"

API_ROOT = "https://api.appstoreconnect.apple.com"

def required_environment(name)
  value = ENV[name].to_s.strip
  abort "Missing #{name}" if value.empty?
  value
end

def base64url(value)
  Base64.urlsafe_encode64(value, padding: false)
end

def raw_es256_signature(der_signature)
  sequence = OpenSSL::ASN1.decode(der_signature)
  sequence.value.map { |part| part.value.to_s(2).rjust(32, "\0")[-32, 32] }.join
end

def app_store_connect_jwt(key_id:, issuer_id:, private_key_path:)
  header = base64url(JSON.generate({ alg: "ES256", kid: key_id, typ: "JWT" }))
  now = Time.now.to_i
  payload = base64url(
    JSON.generate({ iss: issuer_id, iat: now, exp: now + 1_000, aud: "appstoreconnect-v1" })
  )
  signing_input = "#{header}.#{payload}"
  key = OpenSSL::PKey::EC.new(File.read(private_key_path))
  signature = raw_es256_signature(key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(signing_input)))
  "#{signing_input}.#{base64url(signature)}"
end

def request_json(method, path, token, body: nil)
  uri = URI.join(API_ROOT, path)
  request = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
  request["Authorization"] = "Bearer #{token}"
  request["Content-Type"] = "application/json"
  request.body = JSON.generate(body) if body

  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 60) { |http| http.request(request) }
  return {} if response.code.to_i == 204

  parsed = JSON.parse(response.body.empty? ? "{}" : response.body)
  return parsed if response.code.to_i.between?(200, 299)

  details = parsed.fetch("errors", parsed).to_json
  abort "App Store Connect #{method.to_s.upcase} #{path} failed (HTTP #{response.code}): #{details}"
end

key_id = required_environment("APP_STORE_CONNECT_KEY_ID")
issuer_id = required_environment("APP_STORE_CONNECT_ISSUER_ID")
private_key_path = required_environment("APP_STORE_CONNECT_PRIVATE_KEY_PATH")
bundle_id = required_environment("APP_BUNDLE_ID")
build_number = required_environment("APP_BUILD_NUMBER")
app_store_connect_app_id = required_environment("APP_STORE_CONNECT_APP_ID")
group_name = required_environment("TESTFLIGHT_GROUP_NAME")

token = app_store_connect_jwt(key_id: key_id, issuer_id: issuer_id, private_key_path: private_key_path)
app = request_json(:get, "/v1/apps/#{app_store_connect_app_id}", token).fetch("data")
actual_bundle_id = app.dig("attributes", "bundleId")
abort "App Store Connect app #{app_store_connect_app_id} is #{actual_bundle_id.inspect}, expected #{bundle_id.inspect}" unless actual_bundle_id == bundle_id

groups = request_json(:get, "/v1/apps/#{app_store_connect_app_id}/betaGroups?limit=200", token).fetch("data", [])
matching_groups = groups.select { |candidate| candidate.dig("attributes", "name") == group_name }
unless matching_groups.length == 1
  names = groups.map { |candidate| candidate.dig("attributes", "name") }.compact
  abort "Expected exactly one TestFlight group named #{group_name.inspect}, found #{matching_groups.length}. Available groups: #{names.join(", ")}"
end
group = matching_groups.first
abort "TestFlight group #{group_name.inspect} must be an internal group" unless group.dig("attributes", "isInternalGroup") == true

if ARGV.include?("--preflight")
  puts "Validated App Store app #{app_store_connect_app_id} and internal group #{group_name}."
  exit 0
end

build = nil
40.times do |attempt|
  token = app_store_connect_jwt(key_id: key_id, issuer_id: issuer_id, private_key_path: private_key_path)
  path = "/v1/builds?filter%5Bapp%5D=#{app_store_connect_app_id}&filter%5Bversion%5D=#{URI.encode_www_form_component(build_number)}&sort=-uploadedDate&limit=1"
  candidate = request_json(:get, path, token).fetch("data", []).first
  state = candidate&.dig("attributes", "processingState")
  if candidate && state == "VALID"
    build = candidate
    break
  end

  abort "Uploaded build #{build_number} entered processing state #{state}" if candidate && ["FAILED", "INVALID"].include?(state)

  warn "Waiting for TestFlight processing (attempt #{attempt + 1}/40, state #{state || "not visible"})"
  sleep 30
end
abort "Build #{build_number} did not finish TestFlight processing within 20 minutes" unless build

if group.dig("attributes", "hasAccessToAllBuilds") == true
  puts "Build #{build_number} is available to #{group_name} through automatic access."
  exit 0
end

token = app_store_connect_jwt(key_id: key_id, issuer_id: issuer_id, private_key_path: private_key_path)
request_json(
  :post,
  "/v1/builds/#{build.fetch("id")}/relationships/betaGroups",
  token,
  body: { data: [{ type: "betaGroups", id: group.fetch("id") }] }
)
puts "Distributed build #{build_number} to TestFlight group #{group_name}."
