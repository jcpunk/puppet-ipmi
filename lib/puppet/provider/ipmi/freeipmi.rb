# frozen_string_literal: true

require 'puppet'
require File.join(File.dirname(__FILE__), '..', 'ipmi')

# Base provider for IPMI backends that use the FreeIPMI `bmc-config` command.
class Puppet::Provider::Ipmi::Freeipmi < Puppet::Provider::Ipmi
  # @return [String] path to the bmc-config binary
  def bmcconfig_cmd
    @resource[:bmcconfig_cmd] || '/usr/sbin/bmc-config'
  end

  # @return [String] path to the bmc-info binary
  def bmcinfo_cmd
    @resource[:bmcinfo_cmd] || '/usr/sbin/bmc-info'
  end

  # Execute a bmc-config subcommand.
  #
  # @param argv [Array<String>] subcommand and arguments
  # @param failonfail [Boolean] whether to raise on non-zero exit
  # @param sensitive [Boolean] whether to redact the command in logs
  # @return [Puppet::Util::Execution::ProcessOutput]
  def bmcconfig_exec(argv, failonfail: true, sensitive: false)
    cmd = [bmcconfig_cmd] + Array(argv)
    options = { failonfail: failonfail, combine: true }
    options[:sensitive] = true if sensitive
    Puppet::Util::Execution.execute(cmd, options)
  end

  # Execute a read-only bmc-info probe command.
  #
  # Always runs with failonfail: false so the caller can inspect the exit
  # status; use combine: true so stderr diagnostics are available.
  #
  # @param argv [Array<String>] subcommand and arguments
  # @param sensitive [Boolean] whether to redact the command in logs
  # @return [Puppet::Util::Execution::ProcessOutput]
  def bmcinfo_exec(argv, sensitive: false)
    cmd = [bmcinfo_cmd] + Array(argv)
    options = { failonfail: false, combine: true }
    options[:sensitive] = true if sensitive
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

  # Read a key from a bmc-config section.
  #
  # @param section [String] section name
  # @param key [String] field name
  # @param channel [Integer, nil] optional LAN channel number
  # @return [String, nil]
  def bmc_config_get(section, key, channel: nil)
    data = section_cache(section, channel: channel)
    return nil if data.nil?

    data[key.to_s]
  end

  # Write a key/value pair to a bmc-config section.
  #
  # @param section [String] section name
  # @param key [String] field name
  # @param value [String] field value
  # @param channel [Integer, nil] optional LAN channel number
  # @return [void]
  def bmc_config_set(section, key, value, channel: nil, sensitive: false)
    argv = ['--commit', '--key-pair', "#{section}:#{key}=#{value}"]
    argv += ['--lan-channel-number', channel.to_s] if channel
    bmcconfig_exec(argv, sensitive: sensitive)
  end

  private

  # Cache parsed bmc-config section data per section/channel.
  #
  # @param section [String] section name
  # @param channel [Integer, nil] optional LAN channel number
  # @return [Hash<String, String>]
  def section_cache(section, channel: nil)
    @section_cache ||= {}
    cache_key = [section.to_s, channel]
    @section_cache[cache_key] ||= parse_section(
      bmcconfig_exec(
        ['--checkout', '--section', section.to_s] + (channel ? ['--lan-channel-number', channel.to_s] : []),
      ),
    )
  end

  # Parse bmc-config section output into a hash.
  #
  # @param output [String]
  # @return [Hash<String, String>]
  def parse_section(output)
    result = {}
    return result if output.nil? || output.empty?

    output.each_line do |line|
      stripped = line.strip
      next if stripped.empty? || stripped.start_with?('#', 'Section', 'EndSection')
      next unless stripped =~ %r{^(\S(?:.*\S)?)\s+(.+)$}

      k = Regexp.last_match(1)
      v = Regexp.last_match(2).strip
      result[k] = v unless k.empty?
    end
    result
  end

  # Invalidate cached data for a bmc-config section.
  #
  # @param section [String] section name
  # @param channel [Integer, nil] optional LAN channel number
  # @return [void]
  def invalidate_section_cache!(section, channel: nil)
    return unless defined?(@section_cache)

    @section_cache.delete([section.to_s, channel])
  end
end
