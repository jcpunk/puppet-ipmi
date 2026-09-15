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

  # @return [Symbol, nil] :dhcp or :static depending on the BMC configuration
  def type
    kv = parse_lan_print
    source = kv['IP Address Source']
    return nil if source.nil?

    source.include?('DHCP') ? :dhcp : :static
  end

  # @param val [Symbol] :dhcp or :static
  # @return [void]
  def type=(val)
    if val.to_s == 'dhcp'
      ipmitool_exec(['lan', 'set', lan_channel.to_s, 'ipsrc', 'dhcp'])
    else
      ipmitool_exec(['lan', 'set', lan_channel.to_s, 'ipsrc', 'static'])
    end
    invalidate_lan_print_cache!
  end

  # @return [String, nil] current IP address
  def ip
    parse_lan_print['IP Address']
  end

  # @param val [String] IP address to set
  # @return [void]
  def ip=(val)
    ipmitool_exec(['lan', 'set', lan_channel.to_s, 'ipaddr', val.to_s])
    invalidate_lan_print_cache!
  end

  # @return [String, nil] current subnet mask
  def netmask
    parse_lan_print['Subnet Mask']
  end

  # @param val [String] subnet mask to set
  # @return [void]
  def netmask=(val)
    ipmitool_exec(['lan', 'set', lan_channel.to_s, 'netmask', val.to_s])
    invalidate_lan_print_cache!
  end

  # @return [String, nil] current default gateway
  def gateway
    parse_lan_print['Default Gateway IP']
  end

  # @param val [String] default gateway to set
  # @return [void]
  def gateway=(val)
    ipmitool_exec(['lan', 'set', lan_channel.to_s, 'defgw', 'ipaddr', val.to_s])
    invalidate_lan_print_cache!
  end
end
