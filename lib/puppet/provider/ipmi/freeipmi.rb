# frozen_string_literal: true

require 'puppet'
require File.join(File.dirname(__FILE__), '..', 'ipmi')

# Base provider for IPMI backends that use the FreeIPMI `bmc-config` command.
class Puppet::Provider::Ipmi::Freeipmi < Puppet::Provider::Ipmi
  # Execute a bmc-config subcommand.
  #
  # @param argv [Array<String>] subcommand and arguments
  # @param failonfail [Boolean] whether to raise on non-zero exit
  # @param sensitive [Boolean] whether to redact the command in logs
  # @return [Puppet::Util::Execution::ProcessOutput]
  def self.bmcconfig_exec(argv, failonfail: true, sensitive: false)
    cmd = [command(:bmcconfig)] + Array(argv)
    options = { failonfail: failonfail, combine: true }
    options[:sensitive] = true if sensitive
    Puppet::Util::Execution.execute(cmd, options)
  end

  # @see Puppet::Provider::Ipmi::Freeipmi.bmcconfig_exec
  def bmcconfig_exec(argv, failonfail: true, sensitive: false)
    self.class.bmcconfig_exec(argv, failonfail: failonfail, sensitive: sensitive)
  end

  # Build the bmc-config argv for writing one key/value pair.
  #
  # FreeIPMI's --key-pair parser keeps only the first whitespace-separated
  # word of the value, so a value containing whitespace is silently truncated.
  # The value is deliberately omitted from the error message because it may be
  # a password or community string.
  #
  # @return [Array<String>]
  def self.bmc_config_set_argv(section, key, value, channel: nil)
    raise Puppet::Error, "#{section}:#{key}: freeipmi cannot store a value containing whitespace" if value.to_s.match?(%r{\s})

    argv = ['--commit', '--key-pair', "#{section}:#{key}=#{value}"]
    argv += ['--lan-channel-number', channel.to_s] if channel
    argv
  end

  # Write a key/value pair to a bmc-config section.
  #
  # @return [void]
  def self.bmc_config_set(section, key, value, channel: nil, sensitive: false)
    bmcconfig_exec(bmc_config_set_argv(section, key, value, channel: channel), sensitive: sensitive)
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
    bmcconfig_exec(self.class.bmc_config_set_argv(section, key, value, channel: channel), sensitive: sensitive)
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
      next unless stripped =~ %r{^(\S+)\s+(.+)$}

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
