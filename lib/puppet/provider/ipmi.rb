# frozen_string_literal: true

require 'puppet'
require 'puppet/provider'

# Base provider for IPMI-managed resources.
#
# Provides shared helpers for executing ipmitool / bmc-config (freeipmi)
# commands and parsing their output.  Concrete providers inherit from this
# class and override tool-specific methods.
class Puppet::Provider::Ipmi < Puppet::Provider
  # ---------------------------------------------------------------------------
  # Execution helpers
  # ---------------------------------------------------------------------------

  # Run an ipmitool command and return stdout.
  def ipmitool_exec(args, failonfail: false)
    cmd = ipmitool_cmd
    Puppet::Util::Execution.execute("#{cmd} #{args}", failonfail: failonfail)
  end

  # Run a bmc-config (freeipmi) command and return stdout.
  def bmcconfig_exec(args, failonfail: false)
    cmd = bmcconfig_cmd
    Puppet::Util::Execution.execute("#{cmd} #{args}", failonfail: failonfail)
  end

  # Path to the ipmitool binary.
  def ipmitool_cmd
    @resource[:ipmitool_cmd] || '/usr/bin/ipmitool'
  end

  # Path to the bmc-config binary.
  def bmcconfig_cmd
    @resource[:bmcconfig_cmd] || '/usr/sbin/bmc-config'
  end

  # ---------------------------------------------------------------------------
  # Parsing helpers
  # ---------------------------------------------------------------------------

  # Parse key-value output from ipmitool (lines like "Key  : Value").
  def parse_ipmitool_kv(output)
    result = {}
    return result if output.nil? || output.empty?

    output.each_line do |line|
      next unless line.include?(':')

      parts = line.split(':', 2)
      key = parts[0].strip
      value = parts[1].strip
      result[key] = value unless key.empty?
    end
    result
  end
end
