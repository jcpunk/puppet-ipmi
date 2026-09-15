# frozen_string_literal: true

require 'puppet'
require 'puppet/provider'
require 'set'

# Base provider for IPMI-managed resources.
#
# Provides generic helpers shared across all IPMI tool implementations.
# Tool-specific execution helpers live in Puppet::Provider::Ipmi::Ipmitool
# and Puppet::Provider::Ipmi::Freeipmi.
class Puppet::Provider::Ipmi < Puppet::Provider
  # IDs already reserved by `user_id => 'auto'` during this Puppet run.
  # This prevents multiple auto resources from selecting the same slot
  # before earlier resources have actually written to the BMC.
  @auto_allocated_user_ids = Set.new

  # The allocation state is stored on the base class so it is shared by all
  # ipmi_user provider subclasses.
  def self.auto_allocated_user_ids
    Puppet::Provider::Ipmi.instance_variable_get(:@auto_allocated_user_ids)
  end

  def self.auto_allocated_user_ids=(value)
    Puppet::Provider::Ipmi.instance_variable_set(:@auto_allocated_user_ids, value)
  end

  # Reset the auto-allocation tracking state. Called from ipmi_user prefetch
  # at the start of each catalog application, and directly by tests.
  #
  # @return [void]
  def self.reset_auto_allocated_user_ids!
    Puppet::Provider::Ipmi.instance_variable_set(:@auto_allocated_user_ids, Set.new)
  end

  # Parse colon-separated key-value output (lines like "Key  : Value").
  # Used by any provider that reads structured output in this format.
  #
  # @param output [String] command output to parse
  # @return [Hash<String, String>]
  def parse_colon_kv(output)
    result = {}
    return result if output.nil? || output.empty?

    output.each_line do |line|
      next unless line.include?(':')

      parts = line.split(':', 2)
      key = parts[0].strip
      value = parts[1].strip
      result[key] = value unless key.empty?
    end
    result
  end

  # Resolve `user_id => 'auto'` to a concrete BMC user slot.
  #
  # `users` is an array of hashes of the form `{ id: Integer, name: String }`
  # describing the current BMC user slots.  A name that is empty or starts
  # with `DISABLED_` is treated as a free slot.
  #
  # Returns the ID of an existing user whose name matches `user_name`, or the
  # lowest unused ID reported by the BMC.  ID 1 is never returned.  If no
  # free slot is available, a Puppet::Error is raised.
  #
  # IDs selected during the current Puppet run are recorded in
  # auto_allocated_user_ids so that multiple `auto` resources cannot
  # resolve to the same slot before any of them have been applied.
  def resolve_auto_user_id(user_name, users)
    allocated = self.class.auto_allocated_user_ids

    existing = users.find { |u| u[:name] == user_name && u[:id] != 1 }
    if existing
      allocated << existing[:id]
      return existing[:id]
    end

    max_id = users.map { |u| u[:id] }.max || 15
    used_ids = users.filter_map do |u|
      name = u[:name].to_s
      u[:id] unless name.empty? || name =~ %r{^DISABLED_}
    end

    used_ids.concat(allocated.to_a)

    (2..max_id).each do |id|
      next if used_ids.include?(id)

      allocated << id
      return id
    end

    raise Puppet::Error, "No free IPMI user slot available for #{user_name}"
  end
end
