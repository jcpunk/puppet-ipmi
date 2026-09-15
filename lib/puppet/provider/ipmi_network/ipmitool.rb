# frozen_string_literal: true

require 'puppet'
require File.join(File.dirname(__FILE__), '..', 'ipmi', 'ipmitool')

Puppet::Type.type(:ipmi_network).provide(
  :ipmitool,
  parent: Puppet::Provider::Ipmi::Ipmitool,
) do
  desc 'Manage BMC network configuration via ipmitool'

  commands ipmitool: 'ipmitool'
  defaultfor kernel: 'Linux'

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  def type
    kv = parse_lan_print
    source = kv['IP Address Source']
    return nil if source.nil?

    source.include?('DHCP') ? :dhcp : :static
  end

  def type=(val)
    if val.to_s == 'dhcp'
      ipmitool_exec(['lan', 'set', lan_channel.to_s, 'ipsrc', 'dhcp'], failonfail: true)
    else
      ipmitool_exec(['lan', 'set', lan_channel.to_s, 'ipsrc', 'static'], failonfail: true)
    end
  end

  def ip
    parse_lan_print['IP Address']
  end

  def ip=(val)
    ipmitool_exec(['lan', 'set', lan_channel.to_s, 'ipaddr', val.to_s], failonfail: true)
  end

  def netmask
    parse_lan_print['Subnet Mask']
  end

  def netmask=(val)
    ipmitool_exec(['lan', 'set', lan_channel.to_s, 'netmask', val.to_s], failonfail: true)
  end

  def gateway
    parse_lan_print['Default Gateway IP']
  end

  def gateway=(val)
    ipmitool_exec(['lan', 'set', lan_channel.to_s, 'defgw', 'ipaddr', val.to_s], failonfail: true)
  end
end
