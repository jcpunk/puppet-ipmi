# frozen_string_literal: true

require 'puppet'
require File.join(File.dirname(__FILE__), '..', 'ipmi', 'freeipmi')

Puppet::Type.type(:ipmi_snmp).provide(
  :freeipmi,
  parent: Puppet::Provider::Ipmi::Freeipmi,
) do
  desc 'Manage BMC SNMP community string via freeipmi (ipmi-pef-config)'

  commands pefconfig: 'ipmi-pef-config'

  # ipmi-pef-config is the same ipmi-config front end as bmc-config, so the
  # base helpers apply; only the binary differs.
  def bmcconfig_exec(argv, failonfail: true, sensitive: false)
    cmd = [command(:pefconfig)] + Array(argv)
    options = { failonfail: failonfail, combine: true }
    options[:sensitive] = true if sensitive
    Puppet::Util::Execution.execute(cmd, options)
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  # @return [String, nil] current SNMP community string
  def community
    bmc_config_get('Community_String', 'Community_String', channel: lan_channel)
  end

  # @param val [String] community string to set
  # @return [void]
  def community=(val)
    bmc_config_set('Community_String', 'Community_String', val.to_s, channel: lan_channel)
  end
end
