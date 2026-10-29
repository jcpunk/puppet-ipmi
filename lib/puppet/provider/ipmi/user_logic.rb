# frozen_string_literal: true

require 'puppet'
require File.join(File.dirname(__FILE__), '..', 'ipmi')
require 'puppet/util/ipmi_lan_channel'
require File.join(File.dirname(__FILE__), 'user_allocator')

# Backend-independent behaviour of the `ipmi_user` providers.
#
# Design rationale: the ordering of steps (name, password, privilege, access),
# the "never touch a slot we do not own" guard and the purge sequence are
# policy, not tool syntax.  They live here once so the ipmitool and freeipmi
# providers cannot drift apart.  A provider includes this module and supplies
# only the class-level primitives below; each is a thin wrapper around its
# command line tool.
#
# Backend primitives (class methods, all take the IPMI user channel):
#
# * `read_users(channel)` -> Array of `{ id:, name:, priv:, enabled: }`.
#   `name` is `''` for an empty slot, `priv` is an Integer (1-4, 15 for NO
#   ACCESS, 0 when unknown) and `enabled` is true or false.
# * `write_name(channel, id, name)`
# * `write_password(channel, id, password)`
# * `password_matches?(channel, id, password)` -> Boolean
# * `write_priv(channel, id, priv)` change the privilege of a live user.
# * `write_access(channel, id, enabled, priv)` enable or disable the slot's
#   channel and SOL access in the order the backend requires.
module Puppet::Provider::Ipmi::UserLogic
  NO_ACCESS_PRIV = 15

  # @param name [String, nil]
  # @return [Boolean] true when a slot name marks the slot as unused
  def self.free_name?(name)
    name.to_s.empty? || name.to_s.start_with?('DISABLED_')
  end

  # @return [String] the placeholder name given to a purged slot
  def self.disabled_name(id)
    "DISABLED_#{id}"
  end

  # Find the slot that already belongs to a user.  Pure function of the BMC
  # table so it can be shared by prefetch and any other caller.
  #
  # With an explicit id the slot must hold the username.  With `:auto` the
  # lowest id holding the username wins; slot 1 is the anonymous slot and is
  # never matched.
  #
  # @param table [Array<Hash>] BMC user table
  # @param username [String]
  # @param requested_id [Integer, Symbol] explicit id or :auto
  # @return [Hash, nil]
  def self.existing_slot(table, username, requested_id)
    return table.find { |u| u[:id] != 1 && u[:name] == username } if requested_id == :auto

    table.find { |u| u[:id] == requested_id && u[:name] == username }
  end

  # Translate a table entry to the property hash a provider instance carries.
  #
  # @param entry [Hash, nil] table entry, nil when the user does not exist
  # @param channel [Integer]
  # @return [Hash]
  def self.property_hash_for(entry, channel)
    return { ensure: :absent } if entry.nil?

    enable = :false
    enable = :true if entry[:enabled] && entry[:priv] != NO_ACCESS_PRIV

    { ensure: :present, name: entry[:name], user_id: entry[:id], priv: entry[:priv], enable: enable, channel: channel }
  end

  # Class-level behaviour mixed into each provider class.
  module ClassMethods
    # Enumerate every named user slot on the default channel, so that
    # `puppet resource ipmi_user` works.
    #
    # @return [Array<Puppet::Provider>]
    def instances
      channel = Puppet::Util::IpmiLanChannel.default_channel(nil)
      read_users(channel).reject { |u| Puppet::Provider::Ipmi::UserLogic.free_name?(u[:name]) }.map do |entry|
        new(Puppet::Provider::Ipmi::UserLogic.property_hash_for(entry, channel).merge(name: entry[:name]))
      end
    end

    # Describe a resource to the allocator.
    #
    # @param resource [Puppet::Type, Hash]
    # @return [Hash]
    def allocation_request(resource)
      {
        title: resource[:name],
        username: resource[:username] || resource[:name],
        user_id: resource[:user_id],
        present: resource[:ensure] != :absent,
      }
    end

    # Build the provider for one resource from an already-read BMC table.
    #
    # @param resource [Puppet::Type, Hash]
    # @param table [Array<Hash>]
    # @param allocation [Hash, nil] this resource's entry from
    #   UserAllocator.allocate; computed for the resource alone when omitted
    # @return [Puppet::Provider]
    def provider_for(resource, table, allocation = nil)
      allocation ||= Puppet::Provider::Ipmi::UserAllocator.allocate(table, [allocation_request(resource)]).fetch(resource[:name])
      username = resource[:username] || resource[:name]
      entry = Puppet::Provider::Ipmi::UserLogic.existing_slot(table, username, resource[:user_id])
      provider = new(Puppet::Provider::Ipmi::UserLogic.property_hash_for(entry, resource[:channel]))
      provider.resource = resource
      provider.slots = table
      provider.allocation = allocation
      provider
    end

    # Read each channel's user table once, allocate slots for every resource
    # on that channel together, and hand each resource a provider bound to
    # the snapshot.
    #
    # @param resources [Hash<String, Puppet::Type>]
    # @return [void]
    def prefetch(resources)
      resources.values.group_by { |r| r[:channel] }.each do |channel, group|
        table = read_users(channel)
        allocations = Puppet::Provider::Ipmi::UserAllocator.allocate(table, group.map { |r| allocation_request(r) })
        group.each { |resource| resource.provider = provider_for(resource, table, allocations.fetch(resource[:name])) }
      end
    end
  end

  def self.included(base)
    base.extend(ClassMethods)
  end

  # @param value [Hash] this resource's entry from UserAllocator.allocate
  attr_writer :allocation

  # The slot this resource manages.  Raises when the allocator found no free
  # slot, so only the affected resource fails.
  #
  # @return [Integer, nil] nil only for an absent user that has no slot
  def resolved_user_id
    @allocation ||= Puppet::Provider::Ipmi::UserAllocator.allocate(slots, [self.class.allocation_request(@resource)]).fetch(@resource[:name])
    raise Puppet::Error, @allocation[:error] if @allocation.key?(:error)

    @allocation[:id]
  end

  # @return [String] target username from the resource
  def user_name
    @resource[:username] || @resource[:name]
  end

  # Unwrap the resource password if it is a Sensitive value.
  #
  # @return [String, nil]
  def real_password
    pw = @resource[:password]
    return nil if pw.nil?

    return pw.unwrap if pw.is_a?(Puppet::Pops::Types::PSensitiveType::Sensitive)

    pw.to_s
  end

  # @return [Array<Hash>] cached BMC user table for the resource's channel
  def slots
    @slots ||= self.class.read_users(channel)
  end

  # @param table [Array<Hash>] snapshot read by prefetch
  attr_writer :slots

  # Drop the cached user table after a write.
  #
  # @return [void]
  def refresh_slots!
    @slots = nil
  end

  # @return [Hash, nil] the table entry for the resolved slot
  def slot_entry
    slots.find { |u| u[:id] == resolved_user_id }
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  # @return [Boolean] true when the BMC holds a slot for the target user
  def exists?
    @property_hash[:ensure] == :present
  end

  # Create (or fully converge) the user in one step.  Puppet skips the other
  # properties on the run that changes `ensure`, so everything is applied here.
  #
  # @return [void]
  def create
    if @resource[:enable] == :false
      disable_user!
    else
      enable_user!
    end
    purge_mismatched_ids! if @resource[:purge_id_mismatch] == :true
  end

  # IPMI cannot delete a slot.  Absent means: named DISABLED_<id> with no
  # channel or SOL access, which the allocator treats as free.
  #
  # @return [void]
  def destroy
    id = @property_hash[:user_id]
    self.class.write_name(channel, id, Puppet::Provider::Ipmi::UserLogic.disabled_name(id))
    self.class.write_access(channel, id, false, NO_ACCESS_PRIV)
    refresh_slots!
  end

  # Passwords cannot be read back from the BMC.
  #
  # @return [Symbol] :absent
  def password
    :absent
  end

  # Test the current BMC password against the desired value.
  #
  # @return [Boolean]
  def password_insync?
    return true if @resource[:enable] == :false

    pw = real_password
    return true if pw.nil? || pw.empty?

    self.class.password_matches?(channel, resolved_user_id, pw)
  rescue StandardError => e
    Puppet.debug("ipmi_user #{user_name}: password check failed: #{e.class}")
    false
  end

  # @param _val [String] ignored; password is read from the resource
  # @return [void]
  def password=(_val)
    return if @resource[:enable] == :false

    pw = real_password
    return if pw.nil? || pw.empty?

    assert_slot_owned!
    self.class.write_password(channel, resolved_user_id, pw)
    refresh_slots!
  end

  # @return [Symbol] :true if the slot grants access, :false otherwise
  def enable
    @property_hash.fetch(:enable, :false)
  end

  # A disabled resource is only converged once the slot has NO ACCESS, which
  # is stricter than the enabled flag alone.
  #
  # @return [Boolean]
  def access_revoked?
    @property_hash[:priv] == NO_ACCESS_PRIV
  end

  # @param val [Symbol] :true to enable, :false to disable
  # @return [void]
  def enable=(val)
    if [:true, true].include?(val)
      enable_user!
    else
      disable_user!
    end
  end

  # @return [Integer, nil] numeric privilege level of the slot
  def priv
    @property_hash[:priv]
  end

  # @param val [Integer] privilege level to set
  # @return [void]
  def priv=(val)
    assert_slot_owned!
    self.class.write_priv(channel, resolved_user_id, val)
    refresh_slots!
  end

  # @return [Symbol] :true if no mismatched slot exists or purge is disabled,
  #   :false otherwise
  def purge_id_mismatch
    return :true unless @resource[:purge_id_mismatch] == :true

    return :false if mismatched_slot_exists?

    :true
  end

  # @param _val [Symbol] ignored; purge is driven by the getter
  # @return [void]
  def purge_id_mismatch=(_val)
    purge_mismatched_ids!
  end

  private

  # Refuse to modify password or privilege unless the resolved slot is owned
  # by the target user.  If a previous name write failed (e.g. the BMC
  # rejected a duplicate name), this prevents the wrong slot from receiving
  # this resource's password or privilege.
  def assert_slot_owned!
    entry = slot_entry
    actual = nil
    actual = entry[:name] unless entry.nil?
    return if actual == user_name

    raise Puppet::Error, "Refusing to modify slot #{resolved_user_id}: expected user '#{user_name}' but slot contains #{actual.inspect}"
  end

  # @return [Array<Hash>] live slots other than the resolved one that hold
  #   the target username
  def mismatched_slots
    slots.select do |entry|
      entry[:id] != resolved_user_id &&
        entry[:name] == user_name &&
        !entry[:name].start_with?('DISABLED_')
    end
  end

  # @return [Boolean] true if another slot holds the target username
  def mismatched_slot_exists?
    !mismatched_slots.empty?
  end

  # Blank and disable any slot (other than resolved_user_id) that holds the
  # target username.
  #
  # @return [void]
  def purge_mismatched_ids!
    mismatched_slots.each do |entry|
      slot = entry[:id]
      Puppet.debug("ipmi_user: purging #{user_name} from slot #{slot} (expected at #{resolved_user_id})")
      self.class.write_name(channel, slot, Puppet::Provider::Ipmi::UserLogic.disabled_name(slot))
      self.class.write_access(channel, slot, false, NO_ACCESS_PRIV)
    end
    refresh_slots!
  end

  # Enable the resolved slot with the configured username, password,
  # privilege and channel access.
  #
  # @return [void]
  def enable_user!
    id = resolved_user_id
    self.class.write_name(channel, id, user_name)

    pw = real_password
    self.class.write_password(channel, id, pw) if pw && !pw.empty?

    self.class.write_access(channel, id, true, @resource[:priv] || 4)
    refresh_slots!
  end

  # Disable the resolved slot by removing privileges and channel access.  An
  # empty slot is named first so the disabled resource still reserves the
  # requested username.
  #
  # @return [void]
  def disable_user!
    id = resolved_user_id
    entry = slot_entry
    current = nil
    current = entry[:name] unless entry.nil?
    Puppet.debug("ipmi_user disable slot #{id}: current_name=#{current.inspect}, desired_name=#{user_name.inspect}")
    self.class.write_name(channel, id, user_name.to_s) if current.to_s.strip.empty? && !user_name.to_s.strip.empty?

    self.class.write_access(channel, id, false, NO_ACCESS_PRIV)
    refresh_slots!
  end
end
