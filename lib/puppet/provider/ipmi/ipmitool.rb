# frozen_string_literal: true

require 'puppet'
require File.join(File.dirname(__FILE__), '..', 'ipmi')

# Base provider for IPMI backends that use the `ipmitool` command.
class Puppet::Provider::Ipmi::Ipmitool < Puppet::Provider::Ipmi
  # @return [String] path to the ipmitool binary
  def ipmitool_cmd
    @resource[:ipmitool_cmd] || '/usr/bin/ipmitool'
  end

  # Execute an ipmitool subcommand.
  #
  # @param argv [Array<String>] subcommand and arguments
  # @param failonfail [Boolean] whether to raise on non-zero exit
  # @param sensitive [Boolean] whether to redact the command in logs
  # @param stdin [String, nil] data to feed on stdin
  # @return [Puppet::Util::Execution::ProcessOutput]
  def ipmitool_exec(argv, failonfail: true, sensitive: false, stdin: nil)
    cmd = [ipmitool_cmd] + Array(argv)
    options = { failonfail: failonfail, combine: true }
    options[:sensitive] = true if sensitive
    options[:stdin] = stdin if stdin
    Puppet::Util::Execution.execute(cmd, options)
  end

  # @return [Integer] IPMI channel for user management
  def channel
    @resource[:channel]
  end

  # @return [Integer] IPMI LAN channel for network/SNMP management
  def lan_channel
    @resource[:lan_channel]
  end

  # Parse `ipmitool user list <channel>` output.
  #
  # @return [Array<Hash>] list of user hashes with :id, :name, and :privilege
  def parse_user_list
    return @parse_user_list if defined?(@parse_user_list)

    output = ipmitool_exec(['user', 'list', channel.to_s])
    users = []
    return @parse_user_list = users if output.nil? || output.empty?

    output.each_line do |line|
      stripped = line.strip
      next unless stripped =~ %r{^(\d+)\s+(.*?)\s+(true|false)\s+(true|false)\s+(true|false)\s+(.+)$}

      users << {
        id: Regexp.last_match(1).strip.to_i,
        name: Regexp.last_match(2).strip,
        privilege: Regexp.last_match(6).strip,
      }
    end
    @parse_user_list = users
  end

  # Find a user entry in the cached user list by ID.
  #
  # @param uid [Integer] user slot ID
  # @return [Hash, nil]
  def find_user_by_id(uid)
    parse_user_list.find { |u| u[:id] == uid }
  end

  # Parse `ipmitool lan print <channel>` output into key-value pairs.
  #
  # @return [Hash<String, String>]
  def parse_lan_print
    return @parse_lan_print if defined?(@parse_lan_print)

    output = ipmitool_exec(['lan', 'print', lan_channel.to_s])
    @parse_lan_print = parse_colon_kv(output)
  end
end
