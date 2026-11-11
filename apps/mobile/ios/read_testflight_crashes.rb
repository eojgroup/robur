#!/usr/bin/env ruby
# frozen_string_literal: true

# Read-only diagnostics. Never prints keys, tester contact details or raw logs.
require "base64"
require "openssl"
require_relative "app_store_connect_http"

def encoded(value)
  Base64.urlsafe_encode64(value, padding: false)
end

key_id, issuer, pem, app = %w[APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID APP_STORE_CONNECT_PRIVATE_KEY_P8 APP_STORE_CONNECT_APP_ID].map { |name| ENV.fetch(name) }
abort "Invalid app identifier" unless app.match?(/\A\d+\z/)
header = encoded(JSON.generate(alg: "ES256", kid: key_id, typ: "JWT"))
now = Time.now.to_i
payload = encoded(JSON.generate(iss: issuer, iat: now, exp: now + 600, aud: "appstoreconnect-v1"))
input = "#{header}.#{payload}"
key = OpenSSL::PKey::EC.new(pem)
signature = OpenSSL::ASN1.decode(key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(input))).value.map { |part| part.value.to_s(2).rjust(32, "\0")[-32, 32] }.join
token = "#{input}.#{encoded(signature)}"
client = AppStoreConnectHTTP.new
query = URI.encode_www_form("limit" => 20,
  "fields[betaFeedbackCrashSubmissions]" => "createdDate,deviceModel,osVersion,appUptimeInMilliseconds,build,crashLog")
submissions = client.request(:get, "/v1/apps/#{app}/betaFeedbackCrashSubmissions?#{query}", token).fetch("data", [])
puts "TestFlight crash feedback submissions: #{submissions.length} (latest returned, maximum 20)"
submissions.sort_by { |entry| entry.dig("attributes", "createdDate").to_s }.reverse.each do |entry|
  attributes = entry.fetch("attributes", {})
  build_id = entry.dig("relationships", "build", "data", "id")
  build = build_id && client.request(:get, "/v1/builds/#{build_id}?fields%5Bbuilds%5D=version", token).dig("data", "attributes", "version")
  puts "Date #{attributes['createdDate']} | device #{attributes['deviceModel']} | OS #{attributes['osVersion']} | build #{build} | uptime #{attributes['appUptimeInMilliseconds']}ms"
  log = client.request(:get, "/v1/betaFeedbackCrashSubmissions/#{entry.fetch('id')}/crashLog", token).dig("data", "attributes", "logText").to_s
  # Legacy text and current JSON-formatted Apple crash logs are both useful.
  lines = log.lines.select { |line| line.match?(/Exception Type|Exception Reason|Termination Reason|Crashed Thread|Triggered by Thread|Fatal error|Robur|AttributeGraph|SwiftUI|Charts|HealthKit/) }
  lines.first(30).each { |line| puts line.strip.gsub(/0x[0-9a-fA-F]+/, "[address]")[0, 350] }
end
puts "No tester contact information or complete crash logs were retained."
