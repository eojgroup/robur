#!/usr/bin/env ruby
# frozen_string_literal: true

# Creates or reuses App Store profiles for the imported Apple Distribution
# identity, installs them into the ephemeral runner, and applies the exact
# profile names to the generated Release project. It never persists secrets.

require "base64"
require "cgi"
require "fileutils"
require "json"
require "net/http"
require "openssl"
require "open3"
require "time"
require "uri"
require "xcodeproj"

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
  request_class = { get: Net::HTTP::Get, post: Net::HTTP::Post }.fetch(method)
  request = request_class.new(uri)
  request["Authorization"] = "Bearer #{token}"
  request["Content-Type"] = "application/json"
  request.body = JSON.generate(body) if body

  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 60) { |http| http.request(request) }
  parsed = JSON.parse(response.body.empty? ? "{}" : response.body)
  return parsed if response.code.to_i.between?(200, 299)

  details = parsed.fetch("errors", parsed).to_json
  abort "App Store Connect #{method.to_s.upcase} #{path} failed (HTTP #{response.code}): #{details}"
end

def normalized_serial(value)
  value.to_s.upcase.gsub(/[^0-9A-F]/, "").sub(/\A0+/, "")
end

def active_profile?(profile)
  attributes = profile.fetch("attributes", {})
  return false unless attributes.fetch("profileState", "ACTIVE") == "ACTIVE"

  expiration = attributes["expirationDate"]
  expiration.nil? || Time.iso8601(expiration) > Time.now + 86_400
rescue ArgumentError
  false
end

def install_profile(profile, directory)
  profile_id = profile.fetch("id")
  profile_content = profile.fetch("attributes").fetch("profileContent")
  abort "Profile #{profile_id} did not include downloadable content" if profile_content.to_s.empty?

  path = File.join(directory, "#{profile_id}.mobileprovision")
  File.binwrite(path, Base64.strict_decode64(profile_content))
  decoded_path = "#{path}.plist"
  stdout, stderr, status = Open3.capture3("security", "cms", "-D", "-i", path, "-o", decoded_path)
  unless status.success?
    diagnostic = stderr.to_s.strip.empty? ? stdout.to_s.strip : stderr.to_s.strip
    abort "Could not decode profile #{profile_id}: #{diagnostic}"
  end

  name, name_error, name_status = Open3.capture3(
    "/usr/libexec/PlistBuddy", "-c", "Print:Name", decoded_path
  )
  abort "Could not read profile name #{profile_id}: #{name_error}" unless name_status.success?

  File.delete(decoded_path)
  name.strip
end

def patch_release_signing(project_path, team_id, profiles_by_target)
  abort "Generated project is missing: #{project_path}" unless Dir.exist?(project_path)

  project = Xcodeproj::Project.open(project_path)
  target_attributes = project.root_object.attributes["TargetAttributes"] ||= {}

  profiles_by_target.each do |target_name, profile_name|
    target = project.targets.find { |candidate| candidate.name == target_name }
    abort "Generated project is missing target #{target_name}" unless target

    release = target.build_configurations.find { |configuration| configuration.name == "Release" }
    abort "Target #{target_name} has no Release configuration" unless release

    release.build_settings["CODE_SIGN_STYLE"] = "Manual"
    release.build_settings["CODE_SIGN_IDENTITY"] = "Apple Distribution"
    release.build_settings["DEVELOPMENT_TEAM"] = team_id
    release.build_settings["PROVISIONING_PROFILE_SPECIFIER"] = profile_name

    attributes = target_attributes[target.uuid] ||= {}
    attributes["DevelopmentTeam"] = team_id
    attributes["ProvisioningStyle"] = "Manual"
  end

  project.save
end

key_id = required_environment("APP_STORE_CONNECT_KEY_ID")
issuer_id = required_environment("APP_STORE_CONNECT_ISSUER_ID")
private_key_path = required_environment("APP_STORE_CONNECT_PRIVATE_KEY_PATH")
certificate_path = required_environment("DISTRIBUTION_CERTIFICATE_PATH")
team_id = required_environment("APPLE_TEAM_ID")
bundle_id = required_environment("APP_BUNDLE_ID")
github_env = required_environment("GITHUB_ENV")
runner_temp = required_environment("RUNNER_TEMP")

token = app_store_connect_jwt(key_id: key_id, issuer_id: issuer_id, private_key_path: private_key_path)
certificate = OpenSSL::X509::Certificate.new(File.read(certificate_path))
certificate_serial = normalized_serial(certificate.serial.to_s(16))
certificates = request_json(
  :get,
  "/v1/certificates?filter%5BcertificateType%5D=DISTRIBUTION&limit=200",
  token
).fetch("data", [])
certificate_resource = certificates.find do |item|
  normalized_serial(item.dig("attributes", "serialNumber")) == certificate_serial
end
abort "The imported Apple Distribution certificate is not active for this App Store Connect team" unless certificate_resource

certificate_id = certificate_resource.fetch("id")
active_profiles = request_json(
  :get,
  "/v1/profiles?filter%5BprofileType%5D=IOS_APP_STORE&filter%5BprofileState%5D=ACTIVE&include=bundleId,certificates&limit=200&limit%5Bcertificates%5D=50",
  token
).fetch("data", [])

identifiers = [bundle_id, "#{bundle_id}.watchkitapp", "#{bundle_id}.widgets", "#{bundle_id}.watchkitapp.widgets"]
profile_directory = File.join(Dir.home, "Library", "MobileDevice", "Provisioning Profiles")
xcode_profile_directory = File.join(Dir.home, "Library", "Developer", "Xcode", "UserData", "Provisioning Profiles")
FileUtils.mkdir_p(profile_directory)
FileUtils.mkdir_p(xcode_profile_directory)
profile_names = {}

identifiers.each do |identifier|
  encoded_identifier = URI.encode_www_form_component(identifier)
  bundle_ids = request_json(
    :get,
    "/v1/bundleIds?filter%5Bidentifier%5D=#{encoded_identifier}&limit=200",
    token
  ).fetch("data", [])
  exact_bundle_ids = bundle_ids.select { |item| item.dig("attributes", "identifier") == identifier }
  if exact_bundle_ids.empty? && identifier.end_with?(".widgets")
    created = request_json(:post, "/v1/bundleIds", token, body: {
      data: { type: "bundleIds", attributes: { identifier: identifier, name: identifier.include?("watchkitapp") ? "Robur Watch Widgets" : "Robur Widgets", platform: "IOS" } }
    }).fetch("data")
    exact_bundle_ids = [created]
    puts "Registered widget extension #{identifier}."
  end
  abort "Expected one exact registered bundle ID for #{identifier}, found #{exact_bundle_ids.length}" unless exact_bundle_ids.length == 1

  bundle_resource_id = exact_bundle_ids.first.fetch("id")
  capabilities_changed = false
  if identifier.end_with?(".widgets")
    capabilities = request_json(:get, "/v1/bundleIds/#{bundle_resource_id}/bundleIdCapabilities?limit=200", token).fetch("data", [])
    unless capabilities.any? { |item| item.dig("attributes", "capabilityType") == "HEALTHKIT" }
      request_json(:post, "/v1/bundleIdCapabilities", token, body: {
        data: { type: "bundleIdCapabilities", attributes: { capabilityType: "HEALTHKIT" },
          relationships: { bundleId: { data: { type: "bundleIds", id: bundle_resource_id } } } }
      })
      capabilities_changed = true
    end
  end
  profile = active_profiles.find do |candidate|
    !capabilities_changed && candidate.dig("relationships", "bundleId", "data", "id") == bundle_resource_id &&
      active_profile?(candidate) &&
      candidate.dig("relationships", "certificates", "data").to_a.any? { |item| item["id"] == certificate_id }
  end

  unless profile
    profile_name = "Robur CI #{identifier} #{certificate_serial[-8, 8]} #{Time.now.utc.strftime("%Y%m%d%H%M%S")}"
    profile = request_json(
      :post,
      "/v1/profiles",
      token,
      body: {
        data: {
          type: "profiles",
          attributes: { name: profile_name, profileType: "IOS_APP_STORE" },
          relationships: {
            bundleId: { data: { type: "bundleIds", id: bundle_resource_id } },
            certificates: { data: [{ type: "certificates", id: certificate_id }] }
          }
        }
      }
    ).fetch("data")
    puts "Created App Store profile for #{identifier}."
  end

  profile = request_json(:get, "/v1/profiles/#{profile.fetch("id")}", token).fetch("data")
  installed_name = install_profile(profile, profile_directory)
  installed_path = File.join(profile_directory, "#{profile.fetch("id")}.mobileprovision")
  FileUtils.cp(installed_path, File.join(xcode_profile_directory, File.basename(installed_path)))
  profile_names[identifier] = installed_name
  puts "Installed App Store profile for #{identifier}."
end

patch_release_signing(
  File.join(__dir__, "Robur.xcodeproj"),
  team_id,
  {
    "Robur" => profile_names.fetch(bundle_id),
    "RoburWatch Watch App" => profile_names.fetch("#{bundle_id}.watchkitapp"),
    "Robur Widgets" => profile_names.fetch("#{bundle_id}.widgets"),
    "Robur Watch Widgets" => profile_names.fetch("#{bundle_id}.watchkitapp.widgets")
  }
)

export_options_path = File.join(runner_temp, "Robur-ExportOptions.plist")
profile_xml = profile_names.map do |identifier, profile_name|
  "        <key>#{CGI.escapeHTML(identifier)}</key>\n        <string>#{CGI.escapeHTML(profile_name)}</string>"
end.join("\n")
File.write(export_options_path, <<~PLIST)
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
      <key>destination</key><string>export</string>
      <key>manageAppVersionAndBuildNumber</key><false/>
      <key>method</key><string>app-store-connect</string>
      <key>signingCertificate</key><string>Apple Distribution</string>
      <key>signingStyle</key><string>manual</string>
      <key>stripSwiftSymbols</key><true/>
      <key>teamID</key><string>#{CGI.escapeHTML(team_id)}</string>
      <key>uploadSymbols</key><true/>
      <key>provisioningProfiles</key>
      <dict>
#{profile_xml}
      </dict>
  </dict>
  </plist>
PLIST

File.open(github_env, "a") do |file|
  file.puts "EXPORT_OPTIONS_PLIST=#{export_options_path}"
end

puts "Prepared deterministic App Store signing for #{profile_names.length} Robur targets."
