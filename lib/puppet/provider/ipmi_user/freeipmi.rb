# frozen_string_literal: true

require 'puppet'
require File.join(File.dirname(__FILE__), '..', 'ipmi', 'freeipmi')

Puppet::Type.type(:ipmi_user).provide(
  :freeipmi,
  parent: Puppet::Provider::Ipmi::Freeipmi,
) do
  desc 'Manage BMC user accounts via freeipmi (bmc-config)'

  confine commands: { bmcconfig: 'bmc-config' }

  def freeipmi_priv_map
    { 4 => 'Administrator', 3 => 'Operator', 2 => 'User', 1 => 'Callback' }
  end

  def resolved_user_id
    return @resolved_user_id if defined?(@resolved_user_id)

    requested = @resource[:user_id]
    @resolved_user_id = if requested == :auto
                          resolve_auto_user_id(user_name, list_all_users)
                        else
                          requested
                        end
  end

  def user_name
    @resource[:user]
  end

  # Build a list of all BMC user slots from a single bmc-config checkout.
  def list_all_users
    return @list_all_users if defined?(@list_all_users)

    output = bmcconfig_exec(['--checkout'])
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

  def max_user_slot
    list_all_users.map { |u| u[:id] }.max || 15
  end

  def real_password
    pw = @resource[:password]
    return nil if pw.nil?

    pw.is_a?(Puppet::Pops::Types::PSensitiveType::Sensitive) ? pw.unwrap : pw.to_s
  end

  def user_section
    "User#{resolved_user_id}"
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  def user
    bmc_config_get(user_section, 'Username')
  end

  def user=(val)
    bmc_config_set(user_section, 'Username', val.to_s)
  end

  def password
    :absent
  end

  def password_insync?
    # freeipmi does not expose a direct password test command; always apply
    # the password so rotation is guaranteed.
    false
  end

  def password=(_val)
    pw = real_password
    bmc_config_set(user_section, 'Password', pw) if pw && !pw.empty?
  end

  def enable
    username = bmc_config_get(user_section, 'Username')
    return :false if username.nil? || username.empty?
    return :false if ['<username-not-set-yet>', 'NULL'].include?(username)

    val = bmc_config_get(user_section, 'Enable_User')
    return :false if val.nil?

    (val =~ %r{^Yes$}i) ? :true : :false
  end

  def enable=(val)
    if [:true, true].include?(val)
      enable_user!
    else
      disable_user!
    end
  end

  def priv
    val = bmc_config_get(user_section, 'Lan_Privilege_Limit')
    return nil if val.nil?

    freeipmi_priv_map.key(val) || 0
  end

  def priv=(val)
    priv_name = freeipmi_priv_map[val] || 'Administrator'
    bmc_config_set(user_section, 'Lan_Privilege_Limit', priv_name)
  end

  def purge_id_mismatch
    mismatched_slot_exists? ? :false : :true
  end

  def purge_id_mismatch=(_val)
    purge_mismatched_ids!
  end

  private

  def mismatched_slot_exists?
    (1..max_user_slot).any? do |slot|
      next if slot == resolved_user_id

      slot_username = bmc_config_get("User#{slot}", 'Username')
      slot_username && slot_username == user_name && slot_username !~ %r{^DISABLED_}
    end
  end

  # Scan all BMC user slots and disable any slot that holds the target
  # username at an ID other than resolved_user_id.
  def purge_mismatched_ids!
    (1..max_user_slot).each do |slot|
      next if slot == resolved_user_id

      slot_section = "User#{slot}"
      slot_username = bmc_config_get(slot_section, 'Username')
      next if slot_username.nil?
      next unless slot_username == user_name
      next if slot_username =~ %r{^DISABLED_}

      Puppet.debug("ipmi_user: purging #{user_name} from slot #{slot} (expected at #{resolved_user_id})")
      bmc_config_set(slot_section, 'Username', "DISABLED_#{slot}")
      bmc_config_set(slot_section, 'Enable_User', 'No')
      bmc_config_set(slot_section, 'Lan_Privilege_Limit', 'No_Access')
      bmc_config_set(slot_section, 'Lan_Enable_IPMI_Msgs', 'No')
      bmc_config_set(slot_section, 'Lan_Enable_Link_Auth', 'No')
      bmc_config_set(slot_section, 'SOL_Payload_Access', 'No')
    end
  end

  def enable_user!
    # Set username
    bmc_config_set(user_section, 'Username', user_name)

    # Set password
    pw = real_password
    bmc_config_set(user_section, 'Password', pw) if pw && !pw.empty?

    # Enable user
    bmc_config_set(user_section, 'Enable_User', 'Yes')

    # Set privilege
    priv_level = @resource[:priv] || 4
    priv_name = freeipmi_priv_map[priv_level] || 'Administrator'
    bmc_config_set(user_section, 'Lan_Privilege_Limit', priv_name)

    # Enable IPMI messaging
    bmc_config_set(user_section, 'Lan_Enable_IPMI_Msgs', 'Yes')

    # Enable link auth
    bmc_config_set(user_section, 'Lan_Enable_Link_Auth', 'Yes')

    # Enable SOL payload
    bmc_config_set(user_section, 'SOL_Payload_Access', 'Yes')
  end

  def disable_user!
    # Disable user
    bmc_config_set(user_section, 'Enable_User', 'No')

    # Set privilege to No Access
    bmc_config_set(user_section, 'Lan_Privilege_Limit', 'No_Access')

    # Disable IPMI messaging
    bmc_config_set(user_section, 'Lan_Enable_IPMI_Msgs', 'No')

    # Disable link auth
    bmc_config_set(user_section, 'Lan_Enable_Link_Auth', 'No')

    # Disable SOL payload
    bmc_config_set(user_section, 'SOL_Payload_Access', 'No')
  end
end
