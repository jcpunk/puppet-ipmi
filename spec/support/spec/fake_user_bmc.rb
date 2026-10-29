# frozen_string_literal: true

# In-memory BMC used to exercise Puppet::Provider::Ipmi::UserLogic without a
# real backend.  Every write is applied to `table` and recorded in `log`.
require 'puppet/provider/ipmi/user_logic'

module FakeUserBmc
  def self.table_with(*entries)
    entries.map { |e| { name: '', priv: Puppet::Provider::Ipmi::UserLogic::NO_ACCESS_PRIV, enabled: false }.merge(e) }
  end

  # @return [Class] a provider class implementing the backend primitives
  def self.provider_class(table, log, password: nil)
    Class.new(Puppet::Provider::Ipmi) do
      include Puppet::Provider::Ipmi::UserLogic

      define_singleton_method(:read_users) { |_channel| table.map(&:dup) }
      define_singleton_method(:write_name) do |_channel, id, name|
        log << [:name, id, name]
        table.find { |u| u[:id] == id }[:name] = name
      end
      define_singleton_method(:write_password) { |_channel, id, pw| log << [:password, id, pw] }
      define_singleton_method(:password_matches?) { |_channel, _id, pw| pw == password }
      define_singleton_method(:write_priv) do |_channel, id, priv|
        log << [:priv, id, priv]
        table.find { |u| u[:id] == id }[:priv] = priv
      end
      define_singleton_method(:write_access) do |_channel, id, enabled, priv|
        log << [:access, id, enabled, priv]
        entry = table.find { |u| u[:id] == id }
        entry[:enabled] = enabled
        entry[:priv] = priv
      end

      def initialize(resource)
        super()
        @resource = resource
      end

      def channel
        @resource[:channel]
      end
    end
  end
end
