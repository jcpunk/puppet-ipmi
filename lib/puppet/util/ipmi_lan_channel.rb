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
      # Resolve the default LAN channel: integer resource title first, then
      # the ipmi.default.channel fact, then 1.  A malformed fact value is
      # treated as unavailable instead of raising ArgumentError with an
      # unhelpful stack trace during catalog application.
      def self.default_channel(title)
        return title.to_i if title.to_s =~ %r{^\d+$}

        begin
          Integer(Facter.value('ipmi.default.channel') || 1)
        rescue ArgumentError, TypeError
          1
        end
      end

      def self.included(base)
        base.newparam(:lan_channel) do
          desc <<-DESC
            The IPMI LAN channel number to configure.
            Derived from the title when the title is an integer.
            Defaults to the ipmi.default.channel fact, or 1 when unavailable.
          DESC

          defaultto do
            Puppet::Util::IpmiLanChannel.default_channel(resource[:name])
          end

          validate do |value|
            unless value.to_s =~ %r{^[1-9]$|^1[0-5]$}
              raise Puppet::Error, 'lan_channel must be an integer between 1 and 15'
            end
          end

          munge(&:to_i)
        end
      end

      # Reject catalogs where two resources of the same type target the same
      # LAN channel.  Without this check, free-form titles let multiple
      # resources manage the same channel, causing them to flip-flop on every
      # run.
      #
      # Defined here (not duplicated per type) so every type that includes
      # this mixin gets identical duplicate-channel protection.
      def pre_run_check
        return unless catalog

        channel = self[:lan_channel]
        duplicates = catalog.resources.select do |r|
          r.is_a?(self.class) && r.name != name && r[:lan_channel] == channel
        end
        return if duplicates.empty?

        type_name = self.class.name.to_s.split('::').last.downcase
        names = ([self] + duplicates).map(&:name).sort.join(', ')
        raise Puppet::Error, "Multiple #{type_name} resources target channel #{channel}: #{names}"
      end
    end
  end
end
