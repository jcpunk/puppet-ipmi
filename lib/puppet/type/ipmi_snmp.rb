# frozen_string_literal: true

require File.join(File.dirname(__FILE__), '..', 'util', 'ipmi_lan_channel')

Puppet::Type.newtype(:ipmi_snmp) do
  include Puppet::Util::IpmiLanChannel

  @doc = <<-DOC
    @summary
      Manages SNMP community string on a BMC LAN channel via IPMI.

    Supports both ipmitool and freeipmi backends.

    The lan channel is derived from the title when it is an integer.
    Otherwise it defaults to the ipmi.default.channel fact or 1.

    @example Set SNMP community string on channel 1
      ipmi_snmp { '1':
        community => 'public',
      }

    @example Set SNMP community string on channel 2
      ipmi_snmp { 'bmc_snmp':
        lan_channel => 2,
        community   => 'secret',
      }
  DOC

  newparam(:name, namevar: true) do
    desc 'Resource title. When it is an integer, the lan channel is derived automatically.'
  end

  newparam(:ipmitool_cmd) do
    desc 'Path to the ipmitool binary (ipmitool only).'
    defaultto '/usr/bin/ipmitool'
    validate do |value|
      raise Puppet::Error, 'ipmitool_cmd must be an absolute path' unless value.start_with?('/')
    end
  end

  newparam(:pefconfig_cmd) do
    desc 'Path to the ipmi-pef-config binary (freeipmi only).'
    defaultto '/usr/sbin/ipmi-pef-config'
    validate do |value|
      raise Puppet::Error, 'pefconfig_cmd must be an absolute path' unless value.start_with?('/')
    end
  end

  newproperty(:community) do
    desc 'SNMP community string.'
    defaultto 'public'
    validate do |value|
      str = value.to_s
      raise Puppet::Error, 'community must be a non-empty string' if str.empty?
      raise Puppet::Error, 'community must be 18 characters or fewer' if str.length > 18
    end
  end
end
