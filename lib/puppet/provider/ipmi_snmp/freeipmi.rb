# frozen_string_literal: true

require 'puppet'
require File.join(File.dirname(__FILE__), '..', 'ipmi', 'freeipmi')

Puppet::Type.type(:ipmi_snmp).provide(
  :freeipmi,
  parent: Puppet::Provider::Ipmi::Freeipmi,
) do
  desc 'Manage BMC SNMP community string via freeipmi (ipmi-pef-config)'

  commands pefconfig: 'ipmi-pef-config'

  # @return [String] path to the ipmi-pef-config binary
  def pefconfig_cmd
    @resource[:pefconfig_cmd] || '/usr/sbin/ipmi-pef-config'
  end

  # Execute an ipmi-pef-config subcommand.
  #
  # @param argv [Array<String>] subcommand and arguments
  # @param failonfail [Boolean] whether to raise on non-zero exit
  # @return [Puppet::Util::Execution::ProcessOutput]
  def pefconfig_exec(argv, failonfail: true)
    cmd = [pefconfig_cmd] + Array(argv)
    Puppet::Util::Execution.execute(cmd, failonfail: failonfail, combine: true)
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  # @return [String, nil] current SNMP community string
  def community
    output = pefconfig_exec(['--checkout', '--section', "Community_String_Channel_#{lan_channel}"])
    return nil if output.nil? || output.empty?

    output.each_line do |line|
      stripped = line.strip
      return Regexp.last_match(1).strip if stripped =~ %r{^Community_String\s+(.+)$}
    end
    nil
  end

  # @param val [String] community string to set
  # @return [void]
  def community=(val)
    pefconfig_exec(
      [
        '--commit',
        '--key-pair',
        "Community_String_Channel_#{lan_channel}:Community_String=#{val}",
      ],
    )
  end
end
