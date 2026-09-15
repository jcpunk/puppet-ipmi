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

    Two resources may not target the same LAN channel; doing so will fail
    the pre-run check instead of fighting on every run.

    @example Configure DHCP on channel 1
      ipmi_network { 'lan1':
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

  newproperty(:type) do
    desc 'IP address source: dhcp or static.  No default; leave unset to skip managing this property.'
    newvalues(:dhcp, :static)
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

  # Reject catalogs where two resources target the same LAN channel.  Without
  # this check, free-form titles let multiple resources manage the same
  # channel, causing them to flip-flop on every run.
  def pre_run_check
    return unless catalog

    channel = self[:lan_channel]
    duplicates = catalog.resources.select do |r|
      r.is_a?(self.class) && r.name != name && r[:lan_channel] == channel
    end
    return if duplicates.empty?

    names = ([self] + duplicates).map(&:name).sort.join(', ')
    raise Puppet::Error, "Multiple ipmi_network resources target channel #{channel}: #{names}"
  end
end
