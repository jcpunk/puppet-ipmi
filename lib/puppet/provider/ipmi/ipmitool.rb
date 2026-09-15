# frozen_string_literal: true

require 'puppet'
require File.join(File.dirname(__FILE__), '..', 'ipmi')

# Base provider for IPMI backends that use the `ipmitool` command.
class Puppet::Provider::Ipmi::Ipmitool < Puppet::Provider::Ipmi
  # Execute an ipmitool subcommand.
  #
  # @param argv [Array<String>] subcommand and arguments
  # @param failonfail [Boolean] whether to raise on non-zero exit
  # @param sensitive [Boolean] whether to redact the command in logs
  # @param stdin [String, nil] data to feed on stdin
  # @return [Puppet::Util::Execution::ProcessOutput]
  def self.ipmitool_exec(argv, failonfail: true, sensitive: false, stdin: nil)
    cmd = [command(:ipmitool)] + Array(argv)
    options = { failonfail: failonfail, combine: true }
    options[:sensitive] = true if sensitive
    options[:stdin] = stdin if stdin
    Puppet::Util::Execution.execute(cmd, options)
  end

  # @see Puppet::Provider::Ipmi::Ipmitool.ipmitool_exec
  def ipmitool_exec(argv, failonfail: true, sensitive: false, stdin: nil)
    self.class.ipmitool_exec(argv, failonfail: failonfail, sensitive: sensitive, stdin: stdin)
  end

  # @return [Integer] IPMI channel for user management
  def channel
    @resource[:channel]
  end

  # @return [Integer] IPMI LAN channel for network/SNMP management
  def lan_channel
    @resource[:lan_channel]
  end

  # Parse `ipmitool lan print <channel>` output into key-value pairs.
  #
  # @return [Hash<String, String>]
  def parse_lan_print
    return @parse_lan_print if defined?(@parse_lan_print)

    output = ipmitool_exec(['lan', 'print', lan_channel.to_s])
    @parse_lan_print = parse_colon_kv(output)
  end

  # Invalidate cached `ipmitool lan print` data.
  #
  # @return [void]
  def invalidate_lan_print_cache!
    remove_instance_variable(:@parse_lan_print) if defined?(@parse_lan_print)
  end
end
