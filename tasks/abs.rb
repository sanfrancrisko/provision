#!/usr/bin/env ruby
require 'json'
require 'net/http'
require 'yaml'
require 'puppet_litmus'
require 'etc'
require_relative '../lib/task_helper'

def provision(platform, inventory_location)
  include PuppetLitmus::InventoryManipulation
  uri = URI.parse('https://cinext-abs.delivery.puppetlabs.net/api/v2/request')
  jenkins_build_url = if ENV['CI'] == 'true' && ENV['TRAVIS'] == 'true'
                        ENV['TRAVIS_JOB_WEB_URL']
                      elsif ENV['CI'] == 'True' && ENV['APPVEYOR'] == 'True'
                        "https://ci.appveyor.com/project/#{ENV['APPVEYOR_REPO_NAME']}/build/job/#{ENV['APPVEYOR_JOB_ID']}"
                      elsif ENV['GITHUB_ACTIONS'] == 'true'
                        "https://github.com/#{ENV['GITHUB_REPOSITORY']}/actions/runs/#{ENV['GITHUB_RUN_ID']}"
                      else
                        'https://litmus_manual'
                      end
  # Job ID must be unique
  job_id = "IAC task PID #{Process.pid}"

  headers = { 'X-AUTH-TOKEN' => token_from_fogfile('abs'), 'Content-Type' => 'application/json' }
  priority = (ENV['CI']) ? 1 : 2
  payload = { 'resources' => { platform => 1 },
              'priority' => priority,
              'job' => { 'id' => job_id,
                         'tags' => { 'user' => Etc.getlogin, 'jenkins_build_url' => jenkins_build_url } } }

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  request = Net::HTTP::Post.new(uri.request_uri, headers)
  request.body = payload.to_json

  # Make an initial request - we should receive a 202 response to indicate the request is being processed
  reply = http.request(request)
  puts "Received: #{reply.code} #{reply.message} - from ABS"
  raise "Error: #{reply}: #{reply.message}" unless reply.is_a?(Net::HTTPAccepted) # should be a 202

  # We want to then poll the API until we get a 200 response, indicating the VMs have been provisioned
  timeout = Time.now.to_i + 600 # Let's poll the API for a max of 10 minutes
  sleep_time = 1

  # Progressively increase the sleep time by 1 second. When we hit 10 seconds, start querying every 30 seconds until we
  # exceed the time out. This is an attempt to strike a balance between quick provisioning and not saturating the ABS
  # API and network if it's taking longer to provision than usual
  while Time.now.to_i < timeout
    sleep (sleep_time <= 10) ? sleep_time : 30 # rubocop:disable Lint/ParenthesesAsGroupedExpression
    reply = http.request(request)
    puts "Received: #{reply.code} #{reply.message} - from ABS"
    break if reply.code == '200' # Our host(s) are provisioned
    raise 'ABS API Error: Received a HTTP 404 response' if reply.code == '404' # Our host(s) will never be provisioned
    sleep_time += 1
  end

  raise 'Timeout: unable to get a 200 response in 10 minutes' if reply.code != '200'

  data = JSON.parse(reply.body)

  hostname = data.first['hostname']
  if platform_uses_ssh(platform)
    node = { 'uri' => hostname,
             'config' => { 'transport' => 'ssh', 'ssh' => { 'user' => 'root', 'password' => 'Qu@lity!', 'host-key-check' => false } },
             'facts' => { 'provisioner' => 'abs', 'platform' => platform, 'job_id' => job_id } }
    group_name = 'ssh_nodes'
  else
    node = { 'uri' => hostname,
             'config' => { 'transport' => 'winrm', 'winrm' => { 'user' => 'Administrator', 'password' => 'Qu@lity!', 'ssl' => false } },
             'facts' => { 'provisioner' => 'abs', 'platform' => platform, 'job_id' => job_id } }
    group_name = 'winrm_nodes'
  end
  inventory_full_path = File.join(inventory_location, 'inventory.yaml')
  inventory_hash = get_inventory_hash(inventory_full_path)
  add_node_to_group(inventory_hash, node, group_name)
  File.open(inventory_full_path, 'w') { |f| f.write inventory_hash.to_yaml }
  { status: 'ok', node_name: hostname, node: node }
end

def tear_down(node_name, inventory_location)
  include PuppetLitmus::InventoryManipulation

  inventory_full_path = File.join(inventory_location, 'inventory.yaml')
  if File.file?(inventory_full_path)
    inventory_hash = inventory_hash_from_inventory_file(inventory_full_path)
    facts = facts_from_node(inventory_hash, node_name)
    platform = facts['platform']
    job_id = facts['job_id']
  end

  uri = URI.parse('https://cinext-abs.delivery.puppetlabs.net/api/v2/return')
  headers = { 'X-AUTH-TOKEN' => token_from_fogfile('abs'), 'Content-Type' => 'application/json' }
  payload = { 'job_id' => job_id,
              'hosts' => [{ 'hostname' => node_name, 'type' => platform, 'engine' => 'vmpooler' }] }
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  request = Net::HTTP::Post.new(uri.request_uri, headers)
  request.body = payload.to_json

  reply = http.request(request)
  raise "Error: #{reply}: #{reply.message}" unless reply.code == '200'

  remove_node(inventory_hash, node_name)

  puts "Removed #{node_name}"
  File.open(inventory_full_path, 'w') { |f| f.write inventory_hash.to_yaml }
  { status: 'ok' }
end

params = JSON.parse(STDIN.read)
platform = params['platform']
action = params['action']
node_name = params['node_name']
inventory_location = sanitise_inventory_location(params['inventory'])
raise 'specify a node_name when tearing down' if action == 'tear_down' && node_name.nil?
raise 'specify a platform when provisioning' if action == 'provision' && platform.nil?
unless node_name.nil? ^ platform.nil?
  case action
  when 'tear_down'
    raise 'specify only a node_name, not platform, when tearing down'
  when 'provision'
    raise 'specify only a platform, not node_name, when provisioning'
  else
    raise 'specify only one of: node_name, platform'
  end
end

begin
  result = provision(platform, inventory_location) if action == 'provision'
  result = tear_down(node_name, inventory_location) if action == 'tear_down'
  puts result.to_json
  exit 0
rescue => e
  puts({ _error: { kind: 'facter_task/failure', msg: e.message } }.to_json)
  exit 1
end
