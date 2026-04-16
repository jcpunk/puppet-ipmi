# frozen_string_literal: true

require 'puppet'
require 'puppet/provider'
require 'shellwords'

# Base provider for IPMI-managed resources.
#
# Provides generic helpers shared across all IPMI tool implementations.
# Tool-specific execution (ipmitool, bmc-config) lives in the concrete
# provider files rather than here.
class Puppet::Provider::Ipmi < Puppet::Provider
  # Shell-escape a value for safe interpolation into command strings.
  def shellescape(val)
    Shellwords.escape(val.to_s)
  end

  # Parse colon-separated key-value output (lines like "Key  : Value").
  # Used by any provider that reads structured output in this format.
  def parse_colon_kv(output)
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
