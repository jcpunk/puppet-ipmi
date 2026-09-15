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

    Two resources may not target the same LAN channel; doing so will fail
    the pre-run check instead of fighting on every run.

    @example Set SNMP community string on channel 1
      ipmi_snmp { 'snmp1':
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

  newproperty(:community) do
    desc 'SNMP community string.'
    defaultto 'public'
    validate do |value|
      str = value.to_s
      raise Puppet::Error, 'community must be a non-empty string' if str.empty?
      raise Puppet::Error, 'community must be 18 characters or fewer' if str.length > 18
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
    raise Puppet::Error, "Multiple ipmi_snmp resources target channel #{channel}: #{names}"
  end
end
