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

  def privilege_map
    { 4 => 'ADMINISTRATOR', 3 => 'OPERATOR', 2 => 'USER', 1 => 'CALLBACK' }
  end

  def resolved_user_id
    return @resolved_user_id if defined?(@resolved_user_id)

    requested = @resource[:user_id]
    @resolved_user_id = if requested == :auto
                          resolve_auto_user_id(user_name, parse_user_list)
                        else
                          requested
                        end
  end

  def user_name
    @resource[:user]
  end

  def real_password
    pw = @resource[:password]
    return nil if pw.nil?

    pw.is_a?(Puppet::Pops::Types::PSensitiveType::Sensitive) ? pw.unwrap : pw.to_s
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  def user
    entry = find_user_by_id(resolved_user_id)
    return nil if entry.nil?

    entry[:name]
  end

  def user=(val)
    ipmitool_exec(['user', 'set', 'name', resolved_user_id.to_s, val.to_s], failonfail: true)
  end

  def password
    :absent
  end

  def password_insync?
    pw = real_password
    return true if pw.nil? || pw.empty?

    capacity = (pw.length <= 16) ? '16' : '20'
    result = ipmitool_exec(
      ['user', 'test', resolved_user_id.to_s, capacity],
      stdin: pw,
      sensitive: true,
      failonfail: false,
    )
    result.exitstatus.zero?
  rescue StandardError
    false
  end

  def password=(_val)
    pw = real_password
    return if pw.nil? || pw.empty?

    capacity = (pw.length <= 16) ? '16' : '20'
    ipmitool_exec(
      ['user', 'set', 'password', resolved_user_id.to_s, pw, capacity],
      failonfail: true,
      sensitive: true,
    )
  end

  def enable
    entry = find_user_by_id(resolved_user_id)
    return :false if entry.nil?
    return :false if entry[:name].nil? || entry[:name].empty?
    return :false if entry[:privilege] == 'NO ACCESS'
    return :false if privilege_map.key(entry[:privilege]).nil?

    :true
  end

  def enable=(val)
    if [:true, true].include?(val)
      enable_user!
    else
      disable_user!
    end
  end

  def priv
    entry = find_user_by_id(resolved_user_id)
    return nil if entry.nil?

    priv_name = entry[:privilege]
    privilege_map.key(priv_name) || 0
  end

  def priv=(val)
    ipmitool_exec(['user', 'priv', resolved_user_id.to_s, val.to_s, channel.to_s], failonfail: true)
    ipmitool_exec(
      ['channel', 'setaccess', channel.to_s, resolved_user_id.to_s, 'callin=on', 'ipmi=on', 'link=on', "privilege=#{val}"],
      failonfail: true,
    )
  end

  def purge_id_mismatch
    mismatched_slot_exists? ? :false : :true
  end

  def purge_id_mismatch=(_val)
    purge_mismatched_ids!
  end

  private

  def mismatched_slot_exists?
    parse_user_list.any? do |entry|
      entry[:id] != resolved_user_id && entry[:name] == user_name
    end
  end

  def purge_mismatched_ids!
    parse_user_list.each do |entry|
      next if entry[:id] == resolved_user_id
      next unless entry[:name] == user_name
      next if entry[:name] =~ %r{^DISABLED_}

      Puppet.debug("ipmi_user: purging #{user_name} from slot #{entry[:id]} (expected at #{resolved_user_id})")
      ipmitool_exec(['user', 'set', 'name', entry[:id].to_s, "DISABLED_#{entry[:id]}"], failonfail: true)
      ipmitool_exec(['user', 'disable', entry[:id].to_s], failonfail: true)
      ipmitool_exec(
        ['channel', 'setaccess', channel.to_s, entry[:id].to_s, 'callin=off', 'ipmi=off', 'link=off', 'privilege=15'],
        failonfail: true,
      )
    end
  end

  def enable_user!
    # Set username
    ipmitool_exec(['user', 'set', 'name', resolved_user_id.to_s, user_name], failonfail: true)

    # Set password
    pw = real_password
    if pw && !pw.empty?
      password_capacity = (pw.length <= 16) ? '16' : '20'
      ipmitool_exec(
        ['user', 'set', 'password', resolved_user_id.to_s, pw, password_capacity],
        failonfail: true,
        sensitive: true,
      )
    end

    # Set privilege
    priv_level = @resource[:priv] || 4
    ipmitool_exec(['user', 'priv', resolved_user_id.to_s, priv_level.to_s, channel.to_s], failonfail: true)

    # Enable user
    ipmitool_exec(['user', 'enable', resolved_user_id.to_s], failonfail: true)

    # Enable SOL payload
    ipmitool_exec(['sol', 'payload', 'enable', channel.to_s, resolved_user_id.to_s], failonfail: true)

    # Set channel access
    ipmitool_exec(
      ['channel', 'setaccess', channel.to_s, resolved_user_id.to_s, 'callin=on', 'ipmi=on', 'link=on', "privilege=#{priv_level}"],
      failonfail: true,
    )
  end

  def disable_user!
    # Set privilege to NO ACCESS (0xF)
    ipmitool_exec(['user', 'priv', resolved_user_id.to_s, '0xF', channel.to_s], failonfail: true)

    # Disable user
    ipmitool_exec(['user', 'disable', resolved_user_id.to_s], failonfail: true)

    # Disable SOL payload
    ipmitool_exec(['sol', 'payload', 'disable', channel.to_s, resolved_user_id.to_s], failonfail: true)

    # Remove channel access
    ipmitool_exec(
      ['channel', 'setaccess', channel.to_s, resolved_user_id.to_s, 'callin=off', 'ipmi=off', 'link=off', 'privilege=15'],
      failonfail: true,
    )
  end
end
