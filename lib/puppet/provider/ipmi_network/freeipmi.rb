# frozen_string_literal: true

require 'puppet'
require File.join(File.dirname(__FILE__), '..', 'ipmi', 'freeipmi')

Puppet::Type.type(:ipmi_network).provide(
  :freeipmi,
  parent: Puppet::Provider::Ipmi::Freeipmi,
) do
  desc 'Manage BMC network configuration via freeipmi (bmc-config)'

  commands bmcconfig: 'bmc-config'

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  # @return [Symbol, nil] :dhcp or :static depending on the BMC configuration
  def type
    val = bmc_config_get('Lan_Conf', 'IP_Address_Source', channel: lan_channel)
    return nil if val.nil?

    (val =~ %r{DHCP}i) ? :dhcp : :static
  end

  # @param val [Symbol] :dhcp or :static
  # @return [void]
  def type=(val)
    source = (val.to_s == 'dhcp') ? 'Use_DHCP' : 'Static'
    bmc_config_set('Lan_Conf', 'IP_Address_Source', source, channel: lan_channel)
  end

  # @return [String, nil] current IP address
  def ip
    bmc_config_get('Lan_Conf', 'IP_Address', channel: lan_channel)
  end

  # @param val [String] IP address to set
  # @return [void]
  def ip=(val)
    bmc_config_set('Lan_Conf', 'IP_Address', val.to_s, channel: lan_channel)
  end

  # @return [String, nil] current subnet mask
  def netmask
    bmc_config_get('Lan_Conf', 'Subnet_Mask', channel: lan_channel)
  end

  # @param val [String] subnet mask to set
  # @return [void]
  def netmask=(val)
    bmc_config_set('Lan_Conf', 'Subnet_Mask', val.to_s, channel: lan_channel)
  end

  # @return [String, nil] current default gateway
  def gateway
    bmc_config_get('Lan_Conf', 'Default_Gateway_IP_Address', channel: lan_channel)
  end

  # @param val [String] default gateway to set
  # @return [void]
  def gateway=(val)
    bmc_config_set('Lan_Conf', 'Default_Gateway_IP_Address', val.to_s, channel: lan_channel)
  end
end
