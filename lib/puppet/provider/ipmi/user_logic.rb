# frozen_string_literal: true

require 'puppet'
require File.join(File.dirname(__FILE__), '..', 'ipmi')

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

  # Resolve the requested user_id, expanding `auto` to a concrete BMC slot.
  #
  # @return [Integer]
  def resolved_user_id
    return @resolved_user_id if defined?(@resolved_user_id)

    requested = @resource[:user_id]
    @resolved_user_id = if requested == :auto
                          resolve_auto_user_id(user_name, slots)
                        else
                          requested
                        end
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

  # @return [String, nil] current username in the resolved slot
  def username
    entry = slot_entry
    return nil if entry.nil?

    entry[:name]
  end

  # @param val [String] username to set
  # @return [void]
  def username=(val)
    self.class.write_name(channel, resolved_user_id, val.to_s)
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

  # @return [Symbol] :true if the slot is enabled, :false otherwise
  def enable
    entry = slot_entry
    return :false if entry.nil?

    no_access = entry[:priv] == NO_ACCESS_PRIV
    name_empty = entry[:name].empty?

    # A disabled resource is only in sync when the slot has a name and
    # NO ACCESS.  Otherwise run disable_user! to create the name and/or revoke
    # access.
    return :true if @resource[:enable] == :false && (name_empty || !no_access)

    # An enabled resource needs a named slot with access.
    return :false if name_empty || no_access

    return :true if entry[:enabled]

    :false
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
    entry = slot_entry
    return nil if entry.nil?

    entry[:priv]
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
    actual = username
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
    current = username
    Puppet.debug("ipmi_user disable slot #{id}: current_name=#{current.inspect}, desired_name=#{user_name.inspect}")
    self.class.write_name(channel, id, user_name.to_s) if current.to_s.strip.empty? && !user_name.to_s.strip.empty?

    self.class.write_access(channel, id, false, NO_ACCESS_PRIV)
    refresh_slots!
  end
end
