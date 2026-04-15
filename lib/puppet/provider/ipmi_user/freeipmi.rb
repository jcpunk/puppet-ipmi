# frozen_string_literal: true

require 'puppet'
require File.join(File.dirname(__FILE__), '..', 'ipmi')

Puppet::Type.type(:ipmi_user).provide(
  :freeipmi,
  parent: Puppet::Provider::Ipmi
) do
  desc 'Manage BMC user accounts via freeipmi (bmc-config)'

  confine commands: { bmcconfig: 'bmc-config' }

  # ---------------------------------------------------------------------------
  # Helper methods
  # ---------------------------------------------------------------------------

  def freeipmi_priv_map
    { 4 => 'Administrator', 3 => 'Operator', 2 => 'User', 1 => 'Callback' }
  end

  def channel
    @resource[:channel]
  end

  def user_id
    @resource[:user_id]
  end

  def user_name
    @resource[:user]
  end

  def real_password
    pw = @resource[:password]
    return nil if pw.nil?

    pw.is_a?(Puppet::Pops::Types::PSensitiveType::Sensitive) ? pw.unwrap : pw.to_s
  end

  def user_section
    "User#{user_id}"
  end

  # Parse bmc-config checkout output for a given section and key.
  def bmc_config_get(section, key)
    output = bmcconfig_exec("--checkout --section #{section} 2>/dev/null")
    return nil if output.nil? || output.empty?

    output.each_line do |line|
      stripped = line.strip
      return Regexp.last_match(1).strip if stripped =~ %r{^#{Regexp.escape(key)}\s+(.+)$}
    end
    nil
  end

  def bmc_config_set(section, key, value)
    bmcconfig_exec(
      "--commit --key-pair \"#{section}:#{key}=#{value}\"",
      failonfail: true
    )
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  def enable
    val = bmc_config_get(user_section, 'Enable_User')
    return :false if val.nil?

    val =~ %r{^Yes$}i ? :true : :false
  end

  def enable=(val)
    if [:true, true].include?(val)
      enable_user!
    else
      disable_user!
    end
  end

  def priv
    val = bmc_config_get(user_section, "Lan_Channel_Channel_#{channel}_Privilege_Limit")
    return nil if val.nil?

    freeipmi_priv_map.key(val) || 0
  end

  def priv=(val)
    priv_name = freeipmi_priv_map[val] || 'Administrator'
    bmc_config_set(user_section, "Lan_Channel_Channel_#{channel}_Privilege_Limit", priv_name)
  end

  private

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
    bmc_config_set(user_section, "Lan_Channel_Channel_#{channel}_Privilege_Limit", priv_name)

    # Enable IPMI messaging
    bmc_config_set(user_section, "Lan_Channel_Channel_#{channel}_IPMI_Messaging", 'Yes')

    # Enable link auth
    bmc_config_set(user_section, "Lan_Channel_Channel_#{channel}_Link_Authentication", 'Yes')

    # Enable SOL payload
    bmc_config_set(user_section, "SOL_Payload_Channel_#{channel}", 'Yes')
  end

  def disable_user!
    # Disable user
    bmc_config_set(user_section, 'Enable_User', 'No')

    # Set privilege to No Access
    bmc_config_set(user_section, "Lan_Channel_Channel_#{channel}_Privilege_Limit", 'No_Access')

    # Disable IPMI messaging
    bmc_config_set(user_section, "Lan_Channel_Channel_#{channel}_IPMI_Messaging", 'No')

    # Disable link auth
    bmc_config_set(user_section, "Lan_Channel_Channel_#{channel}_Link_Authentication", 'No')

    # Disable SOL payload
    bmc_config_set(user_section, "SOL_Payload_Channel_#{channel}", 'No')
  end
end
