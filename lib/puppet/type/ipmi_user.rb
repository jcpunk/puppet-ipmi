# frozen_string_literal: true

Puppet::Type.newtype(:ipmi_user) do
  @doc = <<-DOC
    @summary
      Manages BMC user accounts via IPMI.

    Supports both ipmitool and freeipmi backends.  Manages user name,
    password, privilege level, enabled state, SOL access, and channel
    access in an idempotent fashion.

    The resource title is used as the IPMI username unless the `username`
    property is given explicitly.  `user_id` defaults to `'auto'`, which
    lets the provider select a slot.

    @example Create an admin user
      ipmi_user { 'admin':
        password => Sensitive('s3cret'),
        priv     => 4,
        channel  => 1,
        enable   => true,
      }

    @example Disable a user
      ipmi_user { 'old_user':
        user_id  => 5,
        channel  => 1,
        enable   => false,
      }

    @example Reserve a user ID with a name but no access
      ipmi_user { 'reserved_operator':
        username => 'OPERATOR',
        user_id  => 5,
        channel  => 1,
        enable   => false,
      }

    @example Automatically select a user ID
      ipmi_user { 'auto_user':
        password => Sensitive('s3cret'),
        priv     => 4,
        channel  => 1,
      }

    @example Use a different resource title than username
      ipmi_user { 'admin_account':
        username => 'admin',
        password => Sensitive('s3cret'),
        user_id  => 3,
        priv     => 4,
        channel  => 1,
      }
  DOC

  newparam(:name, namevar: true) do
    desc 'Resource title.  Used as the IPMI username when `username` is not set.'
  end

  newparam(:user_id) do
    desc <<-DESC
      The numeric IPMI user slot ID, or 'auto' to let the provider select one.

      When set to 'auto', the provider first checks for an existing user with
      the requested username and reuses that ID.  Otherwise it selects the
      lowest unused ID reported by the BMC.  ID 1 is the anonymous slot and is
      never returned by 'auto'.

      On SuperMicro IPMI, user id 2 is reserved for the ADMIN username.
      On ASUS IPMI, user id 2 is reserved for the admin username.
    DESC
    defaultto 'auto'
    validate do |value|
      str = value.to_s
      raise Puppet::Error, 'user_id must be a positive integer or "auto"' unless str == 'auto' || (str =~ %r{^\d+$} && value.to_i.positive?)
    end
    munge do |value|
      (value.to_s == 'auto') ? :auto : value.to_i
    end
  end

  newparam(:channel) do
    desc <<-DESC
      The IPMI channel number for user access configuration.
      Defaults to the ipmi.default.channel fact, or 1 when unavailable.
    DESC
    defaultto do
      Integer(Facter.value('ipmi.default.channel') || 1)
    end
    validate do |value|
      unless value.to_s =~ %r{^[1-9]$|^1[0-5]$}
        raise Puppet::Error, 'channel must be an integer between 1 and 15'
      end
    end
    munge(&:to_i)
  end

  newproperty(:username) do
    desc 'The IPMI username to set.  Defaults to the resource title.'
    defaultto do
      @resource[:name]
    end
    validate do |value|
      str = value.to_s
      raise Puppet::Error, 'username must be a non-empty string' if str.empty?
      raise Puppet::Error, 'username must be 16 characters or fewer' if str.length > 16
      raise Puppet::Error, 'username must not contain whitespace' if str =~ %r{\s}
    end

    def insync?(is)
      # When disabling a slot we do not want to rename an existing user;
      # we only remove privileges and access.  This matches the behavior of
      # the 8.0.0 wrapper define.  An empty slot is named by the disable
      # path so the requested username is still reserved.
      return true if @resource[:enable] == :false

      super
    end
  end

  newproperty(:password) do
    desc 'Password for the IPMI user. May be a Sensitive value. Required when enable is true.'

    sensitive true

    def insync?(_is)
      return true if should.nil?

      @resource.provider.password_insync?
    end
  end

  newproperty(:priv) do
    desc <<-DESC
      Privilege level for the user:
        4 - ADMINISTRATOR
        3 - OPERATOR
        2 - USER
        1 - CALLBACK
    DESC
    munge(&:to_i)
    defaultto 4

    def insync?(is)
      # When disabling, privilege gets set to NO ACCESS (0xF / 15)
      # so we skip the priv check when enable is false
      return true if @resource[:enable] == :false

      is.to_i == should.to_i
    end
  end

  newproperty(:enable) do
    desc 'Whether this user account should be enabled or disabled.'
    newvalues(:true, :false)
    defaultto :true
  end

  newproperty(:purge_id_mismatch) do
    desc <<-DESC
      Corrective property. When true, any IPMI user slot that holds the
      given username at an ID other than user_id will be blanked and disabled.

      This is not persistent state; it is a one-time remediation that runs
      whenever a mismatch is detected.
    DESC
    newvalues(:true, :false)
    defaultto :false

    def insync?(is)
      return true if should == :false

      is == :true
    end
  end

  # Validate the resource parameters
  validate do
    if self[:enable] == :true
      priv = self[:priv]
      raise Puppet::Error, "priv must be 1 (CALLBACK), 2 (USER), 3 (OPERATOR), or 4 (ADMINISTRATOR), got #{priv}" unless [1, 2, 3, 4].include?(priv)

      pw = self[:password]
      raise Puppet::Error, "You must supply a password to enable #{self[:username]} with ipmi_user" if pw.nil? || (pw.respond_to?(:empty?) && pw.empty?)

      real_pw = pw.is_a?(Puppet::Pops::Types::PSensitiveType::Sensitive) ? pw.unwrap : pw
      raise Puppet::Error, 'IPMI v2 restricts passwords to 20 or fewer characters' if real_pw.length > 20
    end
  end
end
