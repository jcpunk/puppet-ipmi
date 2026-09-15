# frozen_string_literal: true

require 'puppet'
require File.join(File.dirname(__FILE__), '..', 'ipmi', 'freeipmi')

Puppet::Type.type(:ipmi_network).provide(
  :freeipmi,
  parent: Puppet::Provider::Ipmi::Freeipmi,
) do
  desc 'Manage BMC network configuration via freeipmi (bmc-config)'

  confine commands: { bmcconfig: 'bmc-config' }

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  def type
    val = bmc_config_get('Lan_Conf', 'IP_Address_Source', channel: lan_channel)
    return nil if val.nil?

    (val =~ %r{DHCP}i) ? :dhcp : :static
  end

  def type=(val)
    source = (val.to_s == 'dhcp') ? 'Use_DHCP' : 'Static'
    bmc_config_set('Lan_Conf', 'IP_Address_Source', source, channel: lan_channel)
  end

  def ip
    bmc_config_get('Lan_Conf', 'IP_Address', channel: lan_channel)
  end

  def ip=(val)
    bmc_config_set('Lan_Conf', 'IP_Address', val.to_s, channel: lan_channel)
  end

  def netmask
    bmc_config_get('Lan_Conf', 'Subnet_Mask', channel: lan_channel)
  end

  def netmask=(val)
    bmc_config_set('Lan_Conf', 'Subnet_Mask', val.to_s, channel: lan_channel)
  end

  def gateway
    bmc_config_get('Lan_Conf', 'Default_Gateway_IP_Address', channel: lan_channel)
  end

  def gateway=(val)
    bmc_config_set('Lan_Conf', 'Default_Gateway_IP_Address', val.to_s, channel: lan_channel)
  end
end
