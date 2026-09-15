# frozen_string_literal: true

require 'spec_helper'
require 'puppet/type/ipmi_user'
require 'tempfile'
require 'fileutils'

describe Puppet::Type.type(:ipmi_user).provider(:freeipmi) do
  let(:type) { Puppet::Type.type(:ipmi_user) }
  let(:base_params) do
    {
      name: 'test',
      user: 'NEWUSER',
      password: 'secret',
      channel: 1,
      provider: 'freeipmi',
    }
  end
  let(:asus_checkout) do
    File.read('spec/fixtures/unit/puppet/provider/ipmi_user/bmc_config_checkout_asus.txt')
  end
  let(:supermicro_checkout) do
    File.read('spec/fixtures/unit/puppet/provider/ipmi_user/bmc_config_checkout_supermicro.txt')
  end

  before do
    Puppet::Provider::Ipmi.reset_auto_allocated_user_ids!
  end

  it_behaves_like 'command-confined provider', :bmcconfig

  def resource_for(user_id)
    type.new(
      name: 'test',
      user: 'NEWUSER',
      password: 'secret',
      channel: 1,
      provider: 'freeipmi',
      user_id: user_id,
    )
  end

  describe 'with explicit user_id' do
    let(:provider) { resource_for(4).provider }

    it 'returns the requested id' do
      expect(provider.resolved_user_id).to eq(4)
    end
  end

  describe 'with user_id => auto' do
    let(:provider) { resource_for('auto').provider }

    it 'reuses the id of an existing user with the same name' do
      slam_resource = type.new(base_params.merge(user: 'SLAM', user_id: 'auto'))
      slam_provider = slam_resource.provider

      slam_provider.expects(:bmcconfig_exec).with(['--checkout']).returns(asus_checkout)

      expect(slam_provider.resolved_user_id).to eq(4)
    end

    it 'selects the lowest free slot, skipping id 1' do
      provider.expects(:bmcconfig_exec).with(['--checkout']).returns(supermicro_checkout)

      expect(provider.resolved_user_id).to eq(3)
    end

    it 'never resolves auto to slot 1, even when slot 1 holds the requested name' do
      checkout = supermicro_checkout.gsub(
        '## Username                                   NULL',
        'Username                                      NEWUSER',
      )
      provider.expects(:bmcconfig_exec).with(['--checkout']).returns(checkout)

      expect(provider.resolved_user_id).to eq(3)
    end

    it 'treats DISABLED_* slots as free' do
      disabled_checkout = asus_checkout.gsub('Username                                      SLAM',
                                             'Username                                      DISABLED_4')

      provider.expects(:bmcconfig_exec).with(['--checkout']).returns(disabled_checkout)

      expect(provider.resolved_user_id).to eq(4)
    end

    it 'falls back to a maximum of 15 when checkout output is empty' do
      provider.expects(:bmcconfig_exec).with(['--checkout']).returns('')

      expect(provider.resolved_user_id).to eq(2)
    end

    it 'raises when no free slot is available' do
      full_checkout = +"Section User1\nEndSection\n"
      (2..15).each do |id|
        full_checkout += "Section User#{id}\nUsername user#{id}\nEndSection\n"
      end

      provider.expects(:bmcconfig_exec).with(['--checkout']).returns(full_checkout)

      expect { provider.resolved_user_id }.to raise_error(Puppet::Error, %r{No free IPMI user slot})
    end

    it 'raises when the checkout command fails' do
      result = Puppet::Util::Execution::ProcessOutput.new('Unable to establish LAN session', 1)
      provider.expects(:bmcconfig_exec).with(['--checkout']).raises(Puppet::ExecutionFailure, result)

      expect { provider.resolved_user_id }.to raise_error(Puppet::ExecutionFailure)
    end

    it 'allocates distinct ids for multiple auto resources' do
      resource_a = type.new(base_params.merge(name: 'a', user: 'A', user_id: 'auto'))
      resource_b = type.new(base_params.merge(name: 'b', user: 'B', user_id: 'auto'))
      provider_a = resource_a.provider
      provider_b = resource_b.provider

      provider_a.expects(:bmcconfig_exec).with(['--checkout']).returns(supermicro_checkout)
      provider_b.expects(:bmcconfig_exec).with(['--checkout']).returns(supermicro_checkout)

      id_a = provider_a.resolved_user_id
      id_b = provider_b.resolved_user_id

      expect(id_a).not_to eq(id_b)
      expect([id_a, id_b]).to all(be >= 2)
    end
  end

  describe 'user property' do
    let(:provider) { resource_for(4).provider }

    it 'returns the current username from the BMC' do
      provider.expects(:bmcconfig_exec).with(['--checkout', '--section', 'User4']).returns(<<~SECTION)
        Username                                      SLAM
        Enable_User                                   Yes
      SECTION

      expect(provider.user).to eq('SLAM')
    end

    it 'returns nil when the slot has no username' do
      provider.expects(:bmcconfig_exec).with(['--checkout', '--section', 'User4']).returns('')

      expect(provider.user).to be_nil
    end

    it 'sets the username' do
      provider.expects(:bmcconfig_exec)
              .with(['--commit', '--key-pair', 'User4:Username=NEWUSER'], sensitive: false)

      provider.user = 'NEWUSER'
    end
  end

  describe 'password property' do
    let(:provider) { resource_for(4).provider }

    it 'reports :absent as the current value' do
      expect(provider.password).to eq(:absent)
    end

    it 'returns true when bmc-info authenticates successfully' do
      provider.expects(:bmcconfig_exec).with(['--checkout', '--section', 'User4']).returns(<<~SECTION)
        Lan_Privilege_Limit                           Administrator
      SECTION
      provider.expects(:bmcinfo_exec)
              .with(['-u', 'NEWUSER', '-p', 'secret', '-l', 'Administrator'], sensitive: true)
              .returns(stub('result', exitstatus: 0))

      expect(provider.password_insync?).to be(true)
    end

    it 'returns false when bmc-info authentication fails' do
      provider.expects(:bmcconfig_exec).with(['--checkout', '--section', 'User4']).returns(<<~SECTION)
        Lan_Privilege_Limit                           Administrator
      SECTION
      provider.expects(:bmcinfo_exec)
              .with(['-u', 'NEWUSER', '-p', 'secret', '-l', 'Administrator'], sensitive: true)
              .returns(stub('result', exitstatus: 1))

      expect(provider.password_insync?).to be(false)
    end

    it 'returns false when the slot has no privilege level' do
      provider.expects(:bmcconfig_exec).with(['--checkout', '--section', 'User4']).returns('')

      expect(provider.password_insync?).to be(false)
    end

    it 'sets the password' do
      provider.expects(:bmcconfig_exec)
              .with(['--commit', '--key-pair', 'User4:Password=secret'], sensitive: true)

      provider.password = 'secret'
    end

    it 'unwraps Sensitive passwords' do
      provider.resource[:password] = Puppet::Pops::Types::PSensitiveType::Sensitive.new('secret')
      provider.expects(:bmcconfig_exec)
              .with(['--commit', '--key-pair', 'User4:Password=secret'], sensitive: true)

      provider.password = 'secret'
    end
  end

  describe 'enable property' do
    let(:provider) { resource_for(4).provider }

    it 'is false when the username is not set' do
      provider.expects(:bmcconfig_exec).with(['--checkout', '--section', 'User4']).returns('')

      expect(provider.enable).to eq(:false)
    end

    it 'is false when the user is disabled' do
      provider.expects(:bmcconfig_exec).with(['--checkout', '--section', 'User4']).returns(<<~SECTION)
        Username                                      NEWUSER
        Enable_User                                   No
      SECTION

      expect(provider.enable).to eq(:false)
    end

    it 'is true when the user is enabled' do
      provider.expects(:bmcconfig_exec).with(['--checkout', '--section', 'User4']).returns(<<~SECTION)
        Username                                      NEWUSER
        Enable_User                                   Yes
      SECTION

      expect(provider.enable).to eq(:true)
    end

    it 'enables a user' do
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User4:Username=NEWUSER'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User4:Password=secret'], sensitive: true)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User4:Enable_User=Yes'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User4:Lan_Privilege_Limit=Administrator'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User4:Lan_Enable_IPMI_Msgs=Yes'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User4:Lan_Enable_Link_Auth=Yes'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User4:SOL_Payload_Access=Yes'], sensitive: false)

      provider.enable = :true
    end

    it 'disables a user' do
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User4:Enable_User=No'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User4:Lan_Privilege_Limit=No_Access'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User4:Lan_Enable_IPMI_Msgs=No'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User4:Lan_Enable_Link_Auth=No'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User4:SOL_Payload_Access=No'], sensitive: false)

      provider.enable = :false
    end
  end

  describe 'priv property' do
    let(:provider) { resource_for(4).provider }

    it 'returns the numeric privilege level' do
      provider.expects(:bmcconfig_exec).with(['--checkout', '--section', 'User4']).returns(<<~SECTION)
        Username                                      NEWUSER
        Lan_Privilege_Limit                           Administrator
      SECTION

      expect(provider.priv).to eq(4)
    end

    it 'sets privilege' do
      provider.expects(:bmcconfig_exec)
              .with(['--commit', '--key-pair', 'User4:Lan_Privilege_Limit=Operator'], sensitive: false)

      provider.priv = 3
    end
  end

  describe 'user section caching' do
    let(:provider) { resource_for(4).provider }

    it 'checks out User4 only once per provider instance' do
      provider.expects(:bmcconfig_exec)
              .with(['--checkout', '--section', 'User4'])
              .returns(<<~SECTION)
                Username                                      NEWUSER
                Enable_User                                   Yes
                Lan_Privilege_Limit                           Administrator
              SECTION
              .once

      provider.user
      provider.enable
      provider.priv
    end

    it 'invalidates the section cache after a write' do
      provider.expects(:bmcconfig_exec)
              .with(['--checkout', '--section', 'User4'])
              .returns(<<~SECTION)
                Username                                      NEWUSER
                Enable_User                                   Yes
                Lan_Privilege_Limit                           Administrator
              SECTION
              .twice
      provider.expects(:bmcconfig_exec)
              .with(['--commit', '--key-pair', 'User4:Username=RENAMED'], sensitive: false)

      provider.user
      provider.user = 'RENAMED'
      provider.user
    end
  end

  describe 'when the resource is disabled' do
    it 'does not sync priv or enable' do
      state_dir = Dir.mktmpdir
      Puppet[:statedir] = state_dir

      resource = type.new(
        name: 'test',
        user: 'NEWUSER',
        user_id: 4,
        channel: 1,
        enable: :false,
        priv: 3,
        provider: 'freeipmi',
      )
      catalog = Puppet::Resource::Catalog.new
      catalog.add_resource(resource)
      resource.provider.stubs(:priv).returns(4)
      resource.provider.stubs(:enable).returns(:false)
      resource.provider.expects(:priv=).never
      resource.provider.expects(:enable=).never

      catalog.apply
    ensure
      FileUtils.rm_rf(state_dir)
    end
  end

  describe 'purge_id_mismatch property' do
    let(:provider) { resource_for(4).provider }

    it 'returns :false when a duplicate username exists' do
      provider.expects(:bmcconfig_exec).with(['--checkout']).returns(<<~CHECKOUT)
        Section User1
        EndSection
        Section User2
        Username                                      NEWUSER
        EndSection
        Section User3
        EndSection
        Section User4
        Username                                      NEWUSER
        EndSection
      CHECKOUT

      expect(provider.purge_id_mismatch).to eq(:false)
    end

    it 'returns :true when no duplicate username exists' do
      provider.expects(:bmcconfig_exec).with(['--checkout']).returns(supermicro_checkout)

      expect(provider.purge_id_mismatch).to eq(:true)
    end

    it 'purges duplicate slots' do
      provider.expects(:bmcconfig_exec).with(['--checkout']).returns(<<~CHECKOUT).at_least_once
        Section User1
        EndSection
        Section User2
        Username                                      NEWUSER
        EndSection
        Section User3
        EndSection
        Section User4
        Username                                      NEWUSER
        EndSection
      CHECKOUT
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User2:Username=DISABLED_2'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User2:Enable_User=No'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User2:Lan_Privilege_Limit=No_Access'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User2:Lan_Enable_IPMI_Msgs=No'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User2:Lan_Enable_Link_Auth=No'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User2:SOL_Payload_Access=No'], sensitive: false)

      provider.purge_id_mismatch = :true
    end
  end
end
