# frozen_string_literal: true

require 'resolv'
require File.join(File.dirname(__FILE__), '..', 'util', 'ipmi_lan_channel')

Puppet::Type.newtype(:ipmi_network) do
  include Puppet::Util::IpmiLanChannel

  @doc = <<-DOC
    @summary
      Manages BMC network configuration via IPMI.

    Supports both ipmitool and freeipmi backends.  Each property is
    independently managed - leave a property unset to skip management
    of that setting.

    The lan channel is derived from the title when it is an integer.
    Otherwise it defaults to the ipmi.default.channel fact or 1.

    @example Configure DHCP on channel 1
      ipmi_network { '1':
        type => 'dhcp',
      }

    @example Configure static IP on channel 2
      ipmi_network { 'bmc_network':
        lan_channel => 2,
        type        => 'static',
        ip          => '192.168.1.100',
        netmask     => '255.255.255.0',
        gateway     => '192.168.1.1',
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

  newparam(:bmcconfig_cmd) do
    desc 'Path to the bmc-config binary (freeipmi only).'
    defaultto '/usr/sbin/bmc-config'
    validate do |value|
      raise Puppet::Error, 'bmcconfig_cmd must be an absolute path' unless value.start_with?('/')
    end
  end

  newproperty(:type) do
    desc 'IP address source: dhcp or static.'
    newvalues(:dhcp, :static)
    defaultto :dhcp
  end

  newproperty(:ip) do
    desc 'IP address for the BMC (only used when type is static).'
    validate do |value|
      raise Puppet::Error, "Invalid IP address: #{value}" unless value.to_s =~ Resolv::IPv4::Regex
    end
  end

  newproperty(:netmask) do
    desc 'Subnet mask for the BMC (only used when type is static).'
    validate do |value|
      raise Puppet::Error, "Invalid netmask: #{value}" unless value.to_s =~ Resolv::IPv4::Regex
    end
  end

  newproperty(:gateway) do
    desc 'Default gateway for the BMC (only used when type is static).'
    validate do |value|
      raise Puppet::Error, "Invalid gateway: #{value}" unless value.to_s =~ Resolv::IPv4::Regex
    end
  end

  validate do
    if self[:type] == :dhcp
      [:ip, :netmask, :gateway].each do |prop|
        raise Puppet::Error, "#{prop} cannot be set when type is 'dhcp'" if self[prop]
      end
    end
  end
end
