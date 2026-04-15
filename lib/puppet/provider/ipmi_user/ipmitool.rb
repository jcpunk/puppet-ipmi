# frozen_string_literal: true

require 'puppet'
require File.join(File.dirname(__FILE__), '..', 'ipmi')

Puppet::Type.type(:ipmi_user).provide(
  :ipmitool,
  parent: Puppet::Provider::Ipmi
) do
  desc 'Manage BMC user accounts via ipmitool'

  confine commands: { ipmitool: 'ipmitool' }
  defaultfor kernel: 'Linux'

  # ---------------------------------------------------------------------------
  # Helper methods
  # ---------------------------------------------------------------------------

  def privilege_map
    { 4 => 'ADMINISTRATOR', 3 => 'OPERATOR', 2 => 'USER', 1 => 'CALLBACK' }
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

  # Parse `ipmitool user list <channel>` output and return array of hashes.
  def parse_user_list
    output = ipmitool_exec("user list #{channel} 2>/dev/null")
    users = []
    return users if output.nil? || output.empty?

    output.each_line do |line|
      stripped = line.strip
      next unless stripped =~ %r{^(\d+)\s+(.+?)(\s+(true|false)\s+){3}(USER|ADMINISTRATOR|CALLBACK|OPERATOR|NO ACCESS)$}

      users << {
        id: Regexp.last_match(1).strip.to_i,
        name: Regexp.last_match(2).strip,
        privilege: Regexp.last_match(5).strip,
      }
    end
    users
  end

  # Find a user entry in the user list by ID.
  def find_user_by_id(uid)
    parse_user_list.find { |u| u[:id] == uid }
  end

  # ---------------------------------------------------------------------------
  # Purge ID mismatch
  # ---------------------------------------------------------------------------

  def purge_mismatched_ids!
    return unless [:true, true].include?(@resource[:purge_id_mismatch])
    return unless [:true, true].include?(@resource[:enable])

    parse_user_list.each do |entry|
      next if entry[:id] == user_id
      next unless entry[:name] == user_name
      next if entry[:name] =~ %r{^DISABLED_}

      Puppet.debug("ipmi_user: purging #{user_name} from slot #{entry[:id]} (expected at #{user_id})")
      ipmitool_exec("user set name #{entry[:id]} DISABLED_#{entry[:id]}", failonfail: true)
      ipmitool_exec("user disable #{entry[:id]}", failonfail: true)
      ipmitool_exec(
        "channel setaccess #{channel} #{entry[:id]} callin=off ipmi=off link=off privilege=15",
        failonfail: true
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  def enable
    entry = find_user_by_id(user_id)
    return :false if entry.nil?

    # A user with NO ACCESS privilege is considered disabled
    entry[:privilege] == 'NO ACCESS' ? :false : :true
  end

  def enable=(val)
    purge_mismatched_ids!

    if [:true, true].include?(val)
      enable_user!
    else
      disable_user!
    end
  end

  def priv
    entry = find_user_by_id(user_id)
    return nil if entry.nil?

    priv_name = entry[:privilege]
    privilege_map.key(priv_name) || 0
  end

  def priv=(val)
    ipmitool_exec("user priv #{user_id} #{val} #{channel}", failonfail: true)
    ipmitool_exec(
      "channel setaccess #{channel} #{user_id} callin=on ipmi=on link=on privilege=#{val}",
      failonfail: true
    )
  end

  private

  def enable_user!
    # Set username
    ipmitool_exec("user set name #{user_id} #{shellescape(user_name)}", failonfail: true)

    # Set password
    pw = real_password
    if pw && !pw.empty?
      password_capacity = pw.length <= 16 ? '16' : '20'
      ipmitool_exec(
        "user set password #{user_id} #{shellescape(pw)} #{password_capacity}",
        failonfail: true
      )
    end

    # Set privilege
    priv_level = @resource[:priv] || 4
    ipmitool_exec("user priv #{user_id} #{priv_level} #{channel}", failonfail: true)

    # Enable user
    ipmitool_exec("user enable #{user_id}", failonfail: true)

    # Enable SOL payload
    ipmitool_exec("sol payload enable #{channel} #{user_id}", failonfail: true)

    # Set channel access
    ipmitool_exec(
      "channel setaccess #{channel} #{user_id} callin=on ipmi=on link=on privilege=#{priv_level}",
      failonfail: true
    )
  end

  def disable_user!
    # Set privilege to NO ACCESS (0xF)
    ipmitool_exec("user priv #{user_id} 0xF #{channel}", failonfail: true)

    # Disable user
    ipmitool_exec("user disable #{user_id}", failonfail: true)

    # Disable SOL payload
    ipmitool_exec("sol payload disable #{channel} #{user_id}", failonfail: true)

    # Remove channel access
    ipmitool_exec(
      "channel setaccess #{channel} #{user_id} callin=off ipmi=off link=off privilege=15",
      failonfail: true
    )
  end
end
