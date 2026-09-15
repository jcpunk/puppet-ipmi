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

  # Reset auto-allocation state at the start of each catalog application.
  def self.prefetch(_resources)
    Puppet::Provider::Ipmi.reset_auto_allocated_user_ids!
  end

  # @return [Hash<Integer, String>] mapping of privilege numbers to ipmitool names
  def privilege_map
    { 4 => 'ADMINISTRATOR', 3 => 'OPERATOR', 2 => 'USER', 1 => 'CALLBACK' }
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
    @resource[:user]
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
  def user
    entry = find_user_by_id(resolved_user_id)
    return nil if entry.nil?

    entry[:name]
  end

  # @param val [String] username to set
  # @return [void]
  def user=(val)
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

    capacity = (pw.length <= 16) ? '16' : '20'
    result = ipmitool_exec(
      ['user', 'test', resolved_user_id.to_s, capacity, pw],
      sensitive: true,
      failonfail: false,
    )
    result.exitstatus.zero?
  rescue StandardError
    false
  end

  # @param _val [String] ignored; password is read from the resource
  # @return [void]
  def password=(_val)
    return if @resource[:enable] == :false

    pw = real_password
    return if pw.nil? || pw.empty?

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
    return :false if entry.nil? || entry[:name].empty?

    (entry[:privilege] == 'NO ACCESS') ? :false : :true
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
    ipmitool_exec(['user', 'priv', resolved_user_id.to_s, val.to_s, channel.to_s])
    ipmitool_exec(
      ['channel', 'setaccess', channel.to_s, resolved_user_id.to_s, 'callin=on', 'ipmi=on', 'link=on', "privilege=#{val}"],
    )
    invalidate_user_list_cache!
  end

  # @return [Symbol] :true if no mismatched slot exists, :false otherwise
  def purge_id_mismatch
    mismatched_slot_exists? ? :false : :true
  end

  # @param _val [Symbol] ignored; purge is driven by the getter
  # @return [void]
  def purge_id_mismatch=(_val)
    purge_mismatched_ids!
  end

  private

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
      ipmitool_exec(['user', 'set', 'name', entry[:id].to_s, "DISABLED_#{entry[:id]}"])
      ipmitool_exec(['user', 'disable', entry[:id].to_s])
      ipmitool_exec(
        ['channel', 'setaccess', channel.to_s, entry[:id].to_s, 'callin=off', 'ipmi=off', 'link=off', 'privilege=15'],
      )
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
    # Set privilege to NO ACCESS (0xF)
    ipmitool_exec(['user', 'priv', resolved_user_id.to_s, '0xF', channel.to_s])

    # Disable user
    ipmitool_exec(['user', 'disable', resolved_user_id.to_s])

    # Disable SOL payload
    ipmitool_exec(['sol', 'payload', 'disable', channel.to_s, resolved_user_id.to_s])

    # Remove channel access
    ipmitool_exec(
      ['channel', 'setaccess', channel.to_s, resolved_user_id.to_s, 'callin=off', 'ipmi=off', 'link=off', 'privilege=15'],
    )

    invalidate_user_list_cache!
  end
end
