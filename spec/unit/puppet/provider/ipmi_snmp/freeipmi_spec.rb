# frozen_string_literal: true

require 'spec_helper'
require 'puppet/type/ipmi_snmp'

describe Puppet::Type.type(:ipmi_snmp).provider(:freeipmi) do
  let(:type) { Puppet::Type.type(:ipmi_snmp) }
  let(:pef_conf) do
    File.read('spec/fixtures/unit/puppet/provider/ipmi_snmp/pef_config_community.txt')
  end

  def resource_for(params)
    type.new({ name: 'test', provider: 'freeipmi' }.merge(params))
  end

  describe 'community property' do
    let(:provider) { resource_for(lan_channel: 1).provider }

    it 'returns the current community string' do
      provider.expects(:pefconfig_exec)
              .with(%w[--checkout --section Community_String_Channel_1])
              .returns(pef_conf)

      expect(provider.community).to eq('secret')
    end

    it 'sets the community string' do
      provider.expects(:pefconfig_exec)
              .with(%w[--commit --key-pair Community_String_Channel_1:Community_String=private], failonfail: true)

      provider.community = 'private'
    end
  end
end
