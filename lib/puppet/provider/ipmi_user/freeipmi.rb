# frozen_string_literal: true

require 'puppet'
require File.join(File.dirname(__FILE__), '..', 'ipmi', 'freeipmi')

Puppet::Type.type(:ipmi_user).provide(
  :freeipmi,
  parent: Puppet::Provider::Ipmi::Freeipmi,
) do
  desc 'Manage BMC user accounts via freeipmi (bmc-config)'

  commands bmcconfig: 'bmc-config'

  # Reset auto-allocation state at the start of each catalog application and
  # reserve any user IDs that other resources claim explicitly.
  def self.prefetch(resources)
    Puppet::Provider::Ipmi.reset_auto_allocated_user_ids!
    explicit = resources.each_value.filter_map { |r| r[:user_id] unless r[:user_id] == :auto }
    Puppet::Provider::Ipmi.auto_allocated_user_ids.merge(explicit)
  end

  # @return [Hash<Integer, String>] mapping of privilege numbers to bmc-config names
  def freeipmi_priv_map
    { 4 => 'Administrator', 3 => 'Operator', 2 => 'User', 1 => 'Callback' }
  end

  # Resolve the requested user_id, expanding `auto` to a concrete BMC slot.
  #
  # @return [Integer]
  def resolved_user_id
    return @resolved_user_id if defined?(@resolved_user_id)

    requested = @resource[:user_id]
    @resolved_user_id = if requested == :auto
                          resolve_auto_user_id(user_name, list_all_users)
                        else
                          requested
                        end
  end

  # @return [String] target username from the resource
  def user_name
    @resource[:user]
  end

  # Build a list of all BMC user slots from a single bmc-config checkout.
  #
  # @return [Array<Hash>] list of user hashes with :id and :name
  def list_all_users
    return @list_all_users if defined?(@list_all_users)

    result = bmcconfig_exec(['--checkout'], failonfail: false)
    # Exit 1 can mean either "a key was unreadable but checkout is complete" or
    # an early failure with no configuration.  Only accept it when user sections
    # are actually present, and never include the output in error messages
    # because it may contain keys such as Lan_Conf_Security_Keys.
    complete = result.exitstatus.zero? || (result.exitstatus == 1 && result =~ %r{^\s*Section\s+User\d+}i)
    raise Puppet::Error, "bmc-config --checkout failed (exit #{result.exitstatus})" unless complete

    output = result
    return @list_all_users = [] if output.nil? || output.empty?

    section_ids = []
    names = {}
    current_id = nil
    output.each_line do |line|
      if line =~ %r{^\s*Section\s+User(\d+)}i
        current_id = Regexp.last_match(1).to_i
        section_ids << current_id
      elsif current_id && line =~ %r{^\s*Username\s+(.+)$}
        name = Regexp.last_match(1).strip
        name = '' if ['<username-not-set-yet>', 'NULL'].include?(name)
        names[current_id] = name
        current_id = nil
      end
    end

    @list_all_users = section_ids.sort.map do |id|
      { id: id, name: names.fetch(id, '') }
    end
  end

  # @return [Integer] highest user slot id reported by the BMC
  def max_user_slot
    list_all_users.map { |u| u[:id] }.max || 15
  end

  # Unwrap the resource password if it is a Sensitive value.
  #
  # @return [String, nil]
  def real_password
    pw = @resource[:password]
    return nil if pw.nil?

    pw.is_a?(Puppet::Pops::Types::PSensitiveType::Sensitive) ? pw.unwrap : pw.to_s
  end

  # @return [String] bmc-config section name for the resolved user slot
  def user_section
    "User#{resolved_user_id}"
  end

  # Invalidate cached user list data.
  #
  # @return [void]
  def invalidate_all_users_cache!
    remove_instance_variable(:@list_all_users) if defined?(@list_all_users)
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  # @return [String, nil] current username in the resolved slot
  def user
    bmc_config_get(user_section, 'Username', channel: channel)
  end

  # @param val [String] username to set
  # @return [void]
  def user=(val)
    bmc_config_set(user_section, 'Username', val.to_s, channel: channel)
    invalidate_section_cache!(user_section, channel: channel)
    invalidate_all_users_cache!
  end

  # Passwords cannot be read back from the BMC.
  #
  # @return [Symbol] :absent
  def password
    :absent
  end

  # Test the current BMC password against the desired value using
  # `bmc-config --diff`.  A mismatch line such as `UserN:Password - ...`
  # is only printed when the password differs, and it echoes the password,
  # so the result must never be logged.
  #
  # @return [Boolean]
  def password_insync?
    return true if @resource[:enable] == :false

    pw = real_password
    return true if pw.nil? || pw.empty?

    result = bmcconfig_exec(
      ['--diff', '--key-pair', "#{user_section}:Password=#{pw}"],
      failonfail: false,
      sensitive: true,
    )
    result.exitstatus.zero? && result !~ %r{^#{user_section}:Password\b}
  rescue StandardError
    false
  end

  # @param _val [String] ignored; password is read from the resource
  # @return [void]
  def password=(_val)
    return if @resource[:enable] == :false

    pw = real_password
    return unless pw && !pw.empty?

    assert_slot_owned!
    bmc_config_set(user_section, 'Password', pw, channel: channel, sensitive: true)
    invalidate_section_cache!(user_section, channel: channel)
  end

  # @return [Symbol] :true if the slot is enabled, :false otherwise
  def enable
    username = bmc_config_get(user_section, 'Username', channel: channel)
    return :false if username.nil? || username.empty?
    return :false if ['<username-not-set-yet>', 'NULL'].include?(username)

    val = bmc_config_get(user_section, 'Enable_User', channel: channel)
    return :false if val.nil?
    return :false unless val =~ %r{^Yes$}i

    priv_val = bmc_config_get(user_section, 'Lan_Privilege_Limit', channel: channel)
    return :false if priv_val && priv_val =~ %r{No_Access}i

    :true
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
    val = bmc_config_get(user_section, 'Lan_Privilege_Limit', channel: channel)
    return nil if val.nil?

    freeipmi_priv_map.key(val) || 0
  end

  # @param val [Integer] privilege level to set
  # @return [void]
  def priv=(val)
    assert_slot_owned!
    priv_name = freeipmi_priv_map[val] || 'Administrator'
    bmc_config_set(user_section, 'Lan_Privilege_Limit', priv_name, channel: channel)
    invalidate_section_cache!(user_section, channel: channel)
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
  # by the target user.  If a previous `Username` commit failed (e.g. the BMC
  # rejected a duplicate name), this prevents the wrong slot from receiving
  # this resource's password or privilege.
  def assert_slot_owned!
    actual = user
    return if actual == user_name

    raise Puppet::Error, "Refusing to modify slot #{resolved_user_id}: expected user '#{user_name}' but slot contains #{actual.inspect}"
  end

  # @return [Boolean] true if another slot holds the target username
  def mismatched_slot_exists?
    list_all_users.any? do |entry|
      next if entry[:id] == resolved_user_id

      entry[:name] == user_name && entry[:name] !~ %r{^DISABLED_}
    end
  end

  # Blank and disable any slot (other than resolved_user_id) that holds the
  # target username.
  #
  # @return [void]
  def purge_mismatched_ids!
    list_all_users.each do |entry|
      next if entry[:id] == resolved_user_id

      slot_username = entry[:name]
      next if slot_username.nil? || slot_username.empty?
      next unless slot_username == user_name
      next if slot_username =~ %r{^DISABLED_}

      slot = entry[:id]
      slot_section = "User#{slot}"
      Puppet.debug("ipmi_user: purging #{user_name} from slot #{slot} (expected at #{resolved_user_id})")
      bmc_config_set(slot_section, 'Username', "DISABLED_#{slot}", channel: channel)
      bmc_config_set(slot_section, 'Enable_User', 'No', channel: channel)
      bmc_config_set(slot_section, 'Lan_Privilege_Limit', 'No_Access', channel: channel)
      bmc_config_set(slot_section, 'Lan_Enable_IPMI_Msgs', 'No', channel: channel)
      bmc_config_set(slot_section, 'Lan_Enable_Link_Auth', 'No', channel: channel)
      bmc_config_set(slot_section, 'SOL_Payload_Access', 'No', channel: channel)
      invalidate_section_cache!(slot_section, channel: channel)
    end
    invalidate_all_users_cache!
  end

  # Enable the resolved slot with the configured username, password, privilege,
  # and channel access.
  #
  # @return [void]
  def enable_user!
    # Set username
    bmc_config_set(user_section, 'Username', user_name, channel: channel)

    # Set password
    pw = real_password
    bmc_config_set(user_section, 'Password', pw, channel: channel, sensitive: true) if pw && !pw.empty?

    # Enable user
    bmc_config_set(user_section, 'Enable_User', 'Yes', channel: channel)

    # Set privilege
    priv_level = @resource[:priv] || 4
    priv_name = freeipmi_priv_map[priv_level] || 'Administrator'
    bmc_config_set(user_section, 'Lan_Privilege_Limit', priv_name, channel: channel)

    # Enable IPMI messaging
    bmc_config_set(user_section, 'Lan_Enable_IPMI_Msgs', 'Yes', channel: channel)

    # Enable link auth
    bmc_config_set(user_section, 'Lan_Enable_Link_Auth', 'Yes', channel: channel)

    # Enable SOL payload
    bmc_config_set(user_section, 'SOL_Payload_Access', 'Yes', channel: channel)

    invalidate_section_cache!(user_section, channel: channel)
    invalidate_all_users_cache!
  end

  # Disable the resolved slot by removing privileges and channel access.
  #
  # @return [void]
  def disable_user!
    # Disable user
    bmc_config_set(user_section, 'Enable_User', 'No', channel: channel)

    # Set privilege to No Access
    bmc_config_set(user_section, 'Lan_Privilege_Limit', 'No_Access', channel: channel)

    # Disable IPMI messaging
    bmc_config_set(user_section, 'Lan_Enable_IPMI_Msgs', 'No', channel: channel)

    # Disable link auth
    bmc_config_set(user_section, 'Lan_Enable_Link_Auth', 'No', channel: channel)

    # Disable SOL payload
    bmc_config_set(user_section, 'SOL_Payload_Access', 'No', channel: channel)

    invalidate_section_cache!(user_section, channel: channel)
  end
end
