# frozen_string_literal: true

require 'spec_helper'
require 'puppet/type/ipmi_network'

describe Puppet::Type.type(:ipmi_network).provider(:ipmitool) do
  let(:type) { Puppet::Type.type(:ipmi_network) }
  let(:lan_print) do
    File.read('spec/fixtures/unit/puppet/provider/ipmi_network/ipmitool_lan_print.txt')
  end

  def resource_for(params)
    type.new({ name: 'test', provider: 'ipmitool' }.merge(params))
  end

  describe 'property getters' do
    let(:provider) { resource_for(lan_channel: 1).provider }

    before do
      provider.expects(:ipmitool_exec).with(%w[lan print 1]).returns(lan_print)
    end

    it 'returns type :static' do
      expect(provider.type).to eq(:static)
    end

    it 'returns the ip address' do
      expect(provider.ip).to eq('192.168.56.180')
    end

    it 'returns the netmask' do
      expect(provider.netmask).to eq('255.255.248.0')
    end

    it 'returns the gateway' do
      expect(provider.gateway).to eq('192.168.56.1')
    end
  end

  describe 'property setters' do
    let(:provider) { resource_for(lan_channel: 1).provider }

    it 'sets type to dhcp' do
      provider.expects(:ipmitool_exec).with(%w[lan set 1 ipsrc dhcp], failonfail: true)

      provider.type = :dhcp
    end

    it 'sets type to static' do
      provider.expects(:ipmitool_exec).with(%w[lan set 1 ipsrc static], failonfail: true)

      provider.type = :static
    end

    it 'sets the ip address' do
      provider.expects(:ipmitool_exec).with(%w[lan set 1 ipaddr 192.168.1.100], failonfail: true)

      provider.ip = '192.168.1.100'
    end

    it 'sets the netmask' do
      provider.expects(:ipmitool_exec).with(%w[lan set 1 netmask 255.255.255.0], failonfail: true)

      provider.netmask = '255.255.255.0'
    end

    it 'sets the gateway' do
      provider.expects(:ipmitool_exec).with(%w[lan set 1 defgw ipaddr 192.168.1.1], failonfail: true)

      provider.gateway = '192.168.1.1'
    end
  end
end
