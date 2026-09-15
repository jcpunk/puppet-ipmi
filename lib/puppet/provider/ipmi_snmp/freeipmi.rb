# frozen_string_literal: true

require 'puppet'
require File.join(File.dirname(__FILE__), '..', 'ipmi', 'freeipmi')

Puppet::Type.type(:ipmi_snmp).provide(
  :freeipmi,
  parent: Puppet::Provider::Ipmi::Freeipmi,
) do
  desc 'Manage BMC SNMP community string via freeipmi (ipmi-pef-config)'

  commands pefconfig: 'ipmi-pef-config'
  confine commands: { pefconfig: 'ipmi-pef-config' }

  def pefconfig_cmd
    @resource[:pefconfig_cmd] || '/usr/sbin/ipmi-pef-config'
  end

  def pefconfig_exec(argv, failonfail: false)
    cmd = [pefconfig_cmd] + Array(argv)
    Puppet::Util::Execution.execute(cmd, failonfail: failonfail)
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  def community
    output = pefconfig_exec(['--checkout', '--section', "Community_String_Channel_#{lan_channel}"])
    return nil if output.nil? || output.empty?

    output.each_line do |line|
      stripped = line.strip
      return Regexp.last_match(1).strip if stripped =~ %r{^Community_String\s+(.+)$}
    end
    nil
  end

  def community=(val)
    pefconfig_exec(
      [
        '--commit',
        '--key-pair',
        "Community_String_Channel_#{lan_channel}:Community_String=#{val}",
      ],
      failonfail: true,
    )
  end
end
