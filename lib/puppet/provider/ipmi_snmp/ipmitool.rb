# frozen_string_literal: true

require 'puppet'
require File.join(File.dirname(__FILE__), '..', 'ipmi', 'ipmitool')

Puppet::Type.type(:ipmi_snmp).provide(
  :ipmitool,
  parent: Puppet::Provider::Ipmi::Ipmitool,
) do
  desc 'Manage BMC SNMP community string via ipmitool'

  commands ipmitool: 'ipmitool'
  defaultfor kernel: 'Linux'

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  def community
    parse_lan_print['SNMP Community String']
  end

  def community=(val)
    ipmitool_exec(['lan', 'set', lan_channel.to_s, 'snmp', val.to_s], failonfail: true)
  end
end
