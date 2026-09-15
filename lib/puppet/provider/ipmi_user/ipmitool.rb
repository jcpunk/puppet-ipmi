# frozen_string_literal: true

require 'puppet'
require File.join(File.dirname(__FILE__), '..', 'ipmi', 'ipmitool')

Puppet::Type.type(:ipmi_user).provide(
  :ipmitool,
  parent: Puppet::Provider::Ipmi::Ipmitool,
) do
  desc 'Manage BMC user accounts via ipmitool'

  commands ipmitool: 'ipmitool'
  defaultfor kernel: 'Linux'

  # Reset auto-allocation state at the start of each catalog application and
  # reserve any user IDs that other resources claim explicitly.
  def self.prefetch(resources)
    Puppet::Provider::Ipmi.reset_auto_allocated_user_ids!
    explicit = resources.each_value.filter_map { |r| r[:user_id] unless r[:user_id] == :auto }
    Puppet::Provider::Ipmi.auto_allocated_user_ids.merge(explicit)
  end

  # @return [Hash<Integer, String>] mapping of privilege numbers to ipmitool names
  def privilege_map
    { 4 => 'ADMINISTRATOR', 3 => 'OPERATOR', 2 => 'USER', 1 => 'CALLBACK', 15 => 'NO ACCESS' }
  end

  # @return [Integer] the NO ACCESS privilege level
  def no_access_priv
    privilege_map.key('NO ACCESS')
  end

  # Resolve the requested user_id, expanding `auto` to a concrete BMC slot.
  #
  # @return [Integer]
  def resolved_user_id
    return @resolved_user_id if defined?(@resolved_user_id)

    requested = @resource[:user_id]
    @resolved_user_id = if requested == :auto
                          resolve_auto_user_id(user_name, parse_user_list)
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

    pw.is_a?(Puppet::Pops::Types::PSensitiveType::Sensitive) ? pw.unwrap : pw.to_s
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  # @return [String, nil] current username in the resolved slot
  def username
    entry = find_user_by_id(resolved_user_id)
    return nil if entry.nil?

    entry[:name]
  end

  # @param val [String] username to set
  # @return [void]
  def username=(val)
    ipmitool_exec(['user', 'set', 'name', resolved_user_id.to_s, val.to_s])
    invalidate_user_list_cache!
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

    # Passwords of 16 bytes or fewer may be stored in either 16- or 20-byte
    # form (e.g. written by the web UI or bmc-config), so test both.
    sizes = (pw.length <= 16) ? %w[16 20] : %w[20]
    sizes.any? do |size|
      ipmitool_exec(
        ['user', 'test', resolved_user_id.to_s, size, pw],
        sensitive: true,
        failonfail: false,
      ).exitstatus.zero?
    end
  rescue StandardError
    false
  end

  # @param _val [String] ignored; password is read from the resource
  # @return [void]
  def password=(_val)
    return if @resource[:enable] == :false

    pw = real_password
    return if pw.nil? || pw.empty?

    assert_slot_owned!
    capacity = (pw.length <= 16) ? '16' : '20'
    ipmitool_exec(
      ['user', 'set', 'password', resolved_user_id.to_s, pw, capacity],
      sensitive: true,
    )
    invalidate_user_list_cache!
  end

  # @return [Symbol] :true if the slot is enabled, :false otherwise
  def enable
    entry = find_user_by_id(resolved_user_id)
    return :false if entry.nil?

    no_access = entry[:privilege] == privilege_map[no_access_priv]
    name_empty = entry[:name].empty?

    # A disabled resource is only in sync when the slot has a name and
    # NO ACCESS.  Otherwise run disable_user! to create the name and/or revoke
    # access.
    return :true if @resource[:enable] == :false && (name_empty || !no_access)

    # An enabled resource needs a named slot with access.
    return :false if name_empty
    return :false if no_access

    # `user list` has no enable column; Get User Access reports it.
    access = parse_colon_kv(
      ipmitool_exec(['channel', 'getaccess', channel.to_s, resolved_user_id.to_s]),
    )
    enabled = access.fetch('Enable Status', 'disabled') == 'enabled'

    enabled ? :true : :false
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
    entry = find_user_by_id(resolved_user_id)
    return nil if entry.nil?

    priv_name = entry[:privilege]
    privilege_map.key(priv_name) || 0
  end

  # @param val [Integer] privilege level to set
  # @return [void]
  def priv=(val)
    assert_slot_owned!
    ipmitool_exec(['user', 'priv', resolved_user_id.to_s, val.to_s, channel.to_s])
    ipmitool_exec(
      ['channel', 'setaccess', channel.to_s, resolved_user_id.to_s, 'callin=on', 'ipmi=on', 'link=on', "privilege=#{val}"],
    )
    invalidate_user_list_cache!
  end

  # @return [Symbol] :true if no mismatched slot exists or purge is disabled,
  #   :false otherwise
  def purge_id_mismatch
    return :true unless @resource[:purge_id_mismatch] == :true

    mismatched_slot_exists? ? :false : :true
  end

  # @param _val [Symbol] ignored; purge is driven by the getter
  # @return [void]
  def purge_id_mismatch=(_val)
    purge_mismatched_ids!
  end

  private

  # Refuse to modify password or privilege unless the resolved slot is owned
  # by the target user.  If a previous `user set name` failed (e.g. the BMC
  # rejected a duplicate name), this prevents the wrong slot from receiving
  # this resource's password or privilege.
  def assert_slot_owned!
    actual = username
    return if actual == user_name

    raise Puppet::Error, "Refusing to modify slot #{resolved_user_id}: expected user '#{user_name}' but slot contains #{actual.inspect}"
  end

  # @return [Boolean] true if another slot holds the target username
  def mismatched_slot_exists?
    parse_user_list.any? do |entry|
      entry[:id] != resolved_user_id && entry[:name] == user_name
    end
  end

  # Blank and disable any slot (other than resolved_user_id) that holds the
  # target username.
  #
  # @return [void]
  def purge_mismatched_ids!
    parse_user_list.each do |entry|
      next if entry[:id] == resolved_user_id
      next unless entry[:name] == user_name
      next if entry[:name] =~ %r{^DISABLED_}

      Puppet.debug("ipmi_user: purging #{user_name} from slot #{entry[:id]} (expected at #{resolved_user_id})")
      slot = entry[:id]
      ipmitool_exec(['user', 'set', 'name', slot.to_s, "DISABLED_#{slot}"])
      ipmitool_exec(
        ['channel', 'setaccess', channel.to_s, slot.to_s, 'callin=off', 'ipmi=off', 'link=off', "privilege=#{no_access_priv}"],
      )
      ipmitool_exec(['user', 'disable', slot.to_s])
      invalidate_user_list_cache!
    end
  end

  # Enable the resolved slot with the configured username, password, privilege,
  # and channel access.
  #
  # @return [void]
  def enable_user!
    # Set username
    ipmitool_exec(['user', 'set', 'name', resolved_user_id.to_s, user_name])

    # Set password
    pw = real_password
    if pw && !pw.empty?
      password_capacity = (pw.length <= 16) ? '16' : '20'
      ipmitool_exec(
        ['user', 'set', 'password', resolved_user_id.to_s, pw, password_capacity],
        sensitive: true,
      )
    end

    # Set privilege
    priv_level = @resource[:priv] || 4
    ipmitool_exec(['user', 'priv', resolved_user_id.to_s, priv_level.to_s, channel.to_s])

    # Enable user
    ipmitool_exec(['user', 'enable', resolved_user_id.to_s])

    # Enable SOL payload
    ipmitool_exec(['sol', 'payload', 'enable', channel.to_s, resolved_user_id.to_s])

    # Set channel access
    ipmitool_exec(
      ['channel', 'setaccess', channel.to_s, resolved_user_id.to_s, 'callin=on', 'ipmi=on', 'link=on', "privilege=#{priv_level}"],
    )

    invalidate_user_list_cache!
  end

  # Disable the resolved slot by removing privileges and channel access.
  #
  # @return [void]
  def disable_user!
    # Name an empty slot so disabled resources reserve the requested username.
    current = username
    Puppet.debug("ipmi_user(ipmitool) disable slot #{resolved_user_id}: current_name=#{current.inspect}, desired_name=#{user_name.inspect}")
    if current.to_s.strip.empty? && !user_name.to_s.strip.empty?
      Puppet.debug("ipmi_user(ipmitool): setting name on empty slot #{resolved_user_id} to #{user_name.inspect}")
      ipmitool_exec(['user', 'set', 'name', resolved_user_id.to_s, user_name.to_s])
    end

    # Remove channel access before disabling; some BMCs ignore setaccess on
    # disabled users.
    ipmitool_exec(
      ['channel', 'setaccess', channel.to_s, resolved_user_id.to_s, 'callin=off', 'ipmi=off', 'link=off', "privilege=#{no_access_priv}"],
    )

    # Set privilege to NO ACCESS
    ipmitool_exec(['user', 'priv', resolved_user_id.to_s, no_access_priv.to_s, channel.to_s])

    # Disable user
    ipmitool_exec(['user', 'disable', resolved_user_id.to_s])

    # Disable SOL payload
    ipmitool_exec(['sol', 'payload', 'disable', channel.to_s, resolved_user_id.to_s])

    invalidate_user_list_cache!
  end
end
