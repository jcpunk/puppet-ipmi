# frozen_string_literal: true

require 'puppet'
require File.join(File.dirname(__FILE__), '..', 'ipmi')

Puppet::Type.type(:ipmi_snmp).provide(
  :ipmitool,
  parent: Puppet::Provider::Ipmi
) do
  desc 'Manage BMC SNMP community string via ipmitool'

  confine commands: { ipmitool: 'ipmitool' }
  defaultfor kernel: 'Linux'

  def lan_channel
    @resource[:lan_channel]
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  def community
    output = ipmitool_exec("lan print #{lan_channel} 2>/dev/null")
    kv = parse_ipmitool_kv(output)
    kv['SNMP Community String']
  end

  def community=(val)
    ipmitool_exec("lan set #{lan_channel} snmp #{val}", failonfail: true)
  end
end
