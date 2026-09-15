# frozen_string_literal: true

# Shared LAN channel parameter for IPMI network resources.
#
# This mixin is used by the `ipmi_network` and `ipmi_snmp` native types so
# that both share identical `lan_channel` behavior, validation, and default
# derivation.  Keeping the definition in one place avoids duplicated code
# between the two types.
#
# Why here instead of somewhere else?
#
# * It cannot live under `Puppet::Type::Ipmi` because `Puppet::Type` is a
#   class in Puppet, not a module, so it cannot be used as a namespace.
# * It does not belong in `lib/puppet/provider/ipmi.rb` because that file
#   is the base provider class; channel derivation is a type-level concern,
#   not a provider-level concern.
# * `Puppet::Util` is the conventional namespace for shared Puppet helper
#   code, making this the appropriate location for a mixin used by multiple
#   resource types.
#
# Derives the channel from the resource title when it is an integer,
# otherwise falls back to the ipmi.default.channel fact or 1.
module Puppet
  module Util
    module IpmiLanChannel
      def self.included(base)
        base.newparam(:lan_channel) do
          desc <<-DESC
            The IPMI LAN channel number to configure.
            Derived from the title when the title is an integer.
            Defaults to the ipmi.default.channel fact, or 1 when unavailable.
          DESC

          defaultto do
            title = resource[:name].to_s
            if title =~ %r{^\d+$}
              title.to_i
            else
              Integer(Facter.value('ipmi.default.channel') || 1)
            end
          end

          validate do |value|
            unless value.to_s =~ %r{^[1-9]$|^1[0-5]$}
              raise Puppet::Error, 'lan_channel must be an integer between 1 and 15'
            end
          end

          munge(&:to_i)
        end
      end
    end
  end
end
