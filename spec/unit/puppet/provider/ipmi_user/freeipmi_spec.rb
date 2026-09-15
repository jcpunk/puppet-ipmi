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
    described_class.stubs(:suitable?).returns(true)
    Puppet::Util::Execution.expects(:execute).never
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

  def checkout_result(output, exitstatus: 0)
    Puppet::Util::Execution::ProcessOutput.new(output, exitstatus)
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

      slam_provider.expects(:bmcconfig_exec).with(['--checkout'], failonfail: false).returns(checkout_result(asus_checkout))

      expect(slam_provider.resolved_user_id).to eq(4)
    end

    it 'selects the lowest free slot, skipping id 1' do
      provider.expects(:bmcconfig_exec).with(['--checkout'], failonfail: false).returns(checkout_result(supermicro_checkout))

      expect(provider.resolved_user_id).to eq(3)
    end

    it 'accepts exit status 1 when checkout output contains user sections' do
      provider.expects(:bmcconfig_exec).with(['--checkout'], failonfail: false)
              .returns(checkout_result(supermicro_checkout, exitstatus: 1))

      expect(provider.resolved_user_id).to eq(3)
    end

    it 'never resolves auto to slot 1, even when slot 1 holds the requested name' do
      checkout = supermicro_checkout.gsub(
        '## Username                                   NULL',
        'Username                                      NEWUSER',
      )
      provider.expects(:bmcconfig_exec).with(['--checkout'], failonfail: false).returns(checkout_result(checkout))

      expect(provider.resolved_user_id).to eq(3)
    end

    it 'treats DISABLED_* slots as free' do
      disabled_checkout = asus_checkout.gsub('Username                                      SLAM',
                                             'Username                                      DISABLED_4')

      provider.expects(:bmcconfig_exec).with(['--checkout'], failonfail: false).returns(checkout_result(disabled_checkout))

      expect(provider.resolved_user_id).to eq(4)
    end

    it 'falls back to a maximum of 15 when checkout output is empty' do
      provider.expects(:bmcconfig_exec).with(['--checkout'], failonfail: false).returns(checkout_result(''))

      expect(provider.resolved_user_id).to eq(2)
    end

    it 'raises when no free slot is available' do
      full_checkout = +"Section User1\nEndSection\n"
      (2..15).each do |id|
        full_checkout += "Section User#{id}\nUsername user#{id}\nEndSection\n"
      end

      provider.expects(:bmcconfig_exec).with(['--checkout'], failonfail: false).returns(checkout_result(full_checkout))

      expect { provider.resolved_user_id }.to raise_error(Puppet::Error, %r{No free IPMI user slot})
    end

    it 'raises when the checkout command fails' do
      provider.expects(:bmcconfig_exec).with(['--checkout'], failonfail: false)
              .returns(checkout_result('Unable to establish LAN session', exitstatus: 1))

      expect { provider.resolved_user_id }.to raise_error(Puppet::Error, %r{bmc-config --checkout failed})
    end

    it 'allocates distinct ids for multiple auto resources' do
      resource_a = type.new(base_params.merge(name: 'a', user: 'A', user_id: 'auto'))
      resource_b = type.new(base_params.merge(name: 'b', user: 'B', user_id: 'auto'))
      provider_a = resource_a.provider
      provider_b = resource_b.provider

      provider_a.expects(:bmcconfig_exec).with(['--checkout'], failonfail: false).returns(checkout_result(supermicro_checkout))
      provider_b.expects(:bmcconfig_exec).with(['--checkout'], failonfail: false).returns(checkout_result(supermicro_checkout))

      id_a = provider_a.resolved_user_id
      id_b = provider_b.resolved_user_id

      expect(id_a).not_to eq(id_b)
      expect([id_a, id_b]).to all(be >= 2)
    end
  end

  describe '.prefetch' do
    it 'resets auto-allocation state' do
      Puppet::Provider::Ipmi.auto_allocated_user_ids << 7

      described_class.prefetch('test' => resource_for(3))

      expect(Puppet::Provider::Ipmi.auto_allocated_user_ids).not_to include(7)
    end

    it 'reserves user IDs claimed explicitly by other resources' do
      auto_resource = type.new(base_params.merge(name: 'alice', user: 'alice', user_id: 'auto'))
      explicit_resource = type.new(base_params.merge(name: 'bob', user: 'bob', user_id: 3))

      described_class.prefetch('alice' => auto_resource, 'bob' => explicit_resource)
      auto_provider = auto_resource.provider

      auto_provider.expects(:bmcconfig_exec).with(['--checkout'], failonfail: false).returns(checkout_result(supermicro_checkout))

      expect(auto_provider.resolved_user_id).not_to eq(3)
    end
  end

  describe 'user property' do
    let(:provider) { resource_for(4).provider }

    it 'returns the current username from the BMC' do
      provider.expects(:bmcconfig_exec).with(['--checkout', '--section', 'User4', '--lan-channel-number', '1']).returns(<<~SECTION)
        Username                                      SLAM
        Enable_User                                   Yes
      SECTION

      expect(provider.user).to eq('SLAM')
    end

    it 'returns nil when the slot has no username' do
      provider.expects(:bmcconfig_exec).with(['--checkout', '--section', 'User4', '--lan-channel-number', '1']).returns('')

      expect(provider.user).to be_nil
    end

    it 'sets the username' do
      provider.expects(:bmcconfig_exec)
              .with(['--commit', '--key-pair', 'User4:Username=NEWUSER', '--lan-channel-number', '1'], sensitive: false)

      provider.user = 'NEWUSER'
    end
  end

  describe 'password property' do
    let(:provider) { resource_for(4).provider }

    it 'reports :absent as the current value' do
      expect(provider.password).to eq(:absent)
    end

    it 'returns true when bmc-config --diff reports no mismatch' do
      provider.expects(:bmcconfig_exec)
              .with(['--diff', '--key-pair', 'User4:Password=secret'], failonfail: false, sensitive: true)
              .returns(Puppet::Util::Execution::ProcessOutput.new('', 0))

      expect(provider.password_insync?).to be(true)
    end

    it 'returns false when bmc-config --diff reports a mismatch' do
      provider.expects(:bmcconfig_exec)
              .with(['--diff', '--key-pair', 'User4:Password=secret'], failonfail: false, sensitive: true)
              .returns(Puppet::Util::Execution::ProcessOutput.new("User4:Password - input=secret:actual=old\n", 0))

      expect(provider.password_insync?).to be(false)
    end

    it 'returns false when bmc-config --diff fails' do
      provider.expects(:bmcconfig_exec)
              .with(['--diff', '--key-pair', 'User4:Password=secret'], failonfail: false, sensitive: true)
              .returns(Puppet::Util::Execution::ProcessOutput.new('', 1))

      expect(provider.password_insync?).to be(false)
    end

    it 'sets the password' do
      provider.expects(:bmcconfig_exec).with(['--checkout', '--section', 'User4', '--lan-channel-number', '1']).returns(<<~SECTION)
        Username                                      NEWUSER
      SECTION
      provider.expects(:bmcconfig_exec)
              .with(['--commit', '--key-pair', 'User4:Password=secret', '--lan-channel-number', '1'], sensitive: true)

      provider.password = 'secret'
    end

    it 'sets a 20-character password' do
      long_pw = 's' * 20
      provider.resource[:password] = long_pw
      provider.expects(:bmcconfig_exec).with(['--checkout', '--section', 'User4', '--lan-channel-number', '1']).returns(<<~SECTION)
        Username                                      NEWUSER
      SECTION
      provider.expects(:bmcconfig_exec)
              .with(['--commit', '--key-pair', "User4:Password=#{long_pw}", '--lan-channel-number', '1'], sensitive: true)

      provider.password = long_pw
    end

    it 'raises when the password contains whitespace' do
      provider.expects(:bmcconfig_exec).with(['--checkout', '--section', 'User4', '--lan-channel-number', '1']).returns(<<~SECTION)
        Username                                      NEWUSER
      SECTION

      provider.resource[:password] = 'correct horse'
      expect { provider.password = 'correct horse' }
        .to raise_error(Puppet::Error, %r{freeipmi cannot store a value containing whitespace})
    end

    it 'refuses to set the password when the slot owner does not match' do
      provider.expects(:bmcconfig_exec).with(['--checkout', '--section', 'User4', '--lan-channel-number', '1']).returns(<<~SECTION)
        Username                                      SLAM
      SECTION

      expect { provider.password = 'secret' }.to raise_error(%r{Refusing to modify slot 4: expected user 'NEWUSER' but slot contains "SLAM"})
    end

    it 'does not set the password when enable is false' do
      provider.resource[:enable] = :false
      provider.expects(:bmcconfig_exec).never

      provider.password = 'secret'
    end

    it 'unwraps Sensitive passwords' do
      provider.resource[:password] = Puppet::Pops::Types::PSensitiveType::Sensitive.new('secret')
      provider.expects(:bmcconfig_exec).with(['--checkout', '--section', 'User4', '--lan-channel-number', '1']).returns(<<~SECTION)
        Username                                      NEWUSER
      SECTION
      provider.expects(:bmcconfig_exec)
              .with(['--commit', '--key-pair', 'User4:Password=secret', '--lan-channel-number', '1'], sensitive: true)

      provider.password = 'secret'
    end

    it 'reports the password as in sync when enable is false' do
      provider.resource[:enable] = :false
      provider.expects(:bmcconfig_exec).never

      expect(provider.password_insync?).to be(true)
    end
  end

  describe 'enable property' do
    let(:provider) { resource_for(4).provider }

    it 'is false when the username is not set' do
      provider.expects(:bmcconfig_exec).with(['--checkout', '--section', 'User4', '--lan-channel-number', '1']).returns('')

      expect(provider.enable).to eq(:false)
    end

    it 'is false when the user is disabled' do
      provider.expects(:bmcconfig_exec).with(['--checkout', '--section', 'User4', '--lan-channel-number', '1']).returns(<<~SECTION)
        Username                                      NEWUSER
        Enable_User                                   No
      SECTION

      expect(provider.enable).to eq(:false)
    end

    it 'is true when the user is enabled' do
      provider.expects(:bmcconfig_exec).with(['--checkout', '--section', 'User4', '--lan-channel-number', '1']).returns(<<~SECTION)
        Username                                      NEWUSER
        Enable_User                                   Yes
      SECTION

      expect(provider.enable).to eq(:true)
    end

    it 'is false when the privilege limit is No_Access' do
      provider.expects(:bmcconfig_exec).with(['--checkout', '--section', 'User4', '--lan-channel-number', '1']).returns(<<~SECTION)
        Username                                      NEWUSER
        Enable_User                                   Yes
        Lan_Privilege_Limit                           No_Access
      SECTION

      expect(provider.enable).to eq(:false)
    end

    it 'enables a user' do
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User4:Username=NEWUSER', '--lan-channel-number', '1'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User4:Password=secret', '--lan-channel-number', '1'], sensitive: true)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User4:Enable_User=Yes', '--lan-channel-number', '1'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User4:Lan_Privilege_Limit=Administrator', '--lan-channel-number', '1'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User4:Lan_Enable_IPMI_Msgs=Yes', '--lan-channel-number', '1'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User4:Lan_Enable_Link_Auth=Yes', '--lan-channel-number', '1'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User4:SOL_Payload_Access=Yes', '--lan-channel-number', '1'], sensitive: false)

      provider.enable = :true
    end

    it 'disables a user' do
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User4:Enable_User=No', '--lan-channel-number', '1'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User4:Lan_Privilege_Limit=No_Access', '--lan-channel-number', '1'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User4:Lan_Enable_IPMI_Msgs=No', '--lan-channel-number', '1'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User4:Lan_Enable_Link_Auth=No', '--lan-channel-number', '1'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User4:SOL_Payload_Access=No', '--lan-channel-number', '1'], sensitive: false)

      provider.enable = :false
    end
  end

  describe 'priv property' do
    let(:provider) { resource_for(4).provider }

    it 'returns the numeric privilege level' do
      provider.expects(:bmcconfig_exec).with(['--checkout', '--section', 'User4', '--lan-channel-number', '1']).returns(<<~SECTION)
        Username                                      NEWUSER
        Lan_Privilege_Limit                           Administrator
      SECTION

      expect(provider.priv).to eq(4)
    end

    it 'sets privilege' do
      provider.expects(:bmcconfig_exec).with(['--checkout', '--section', 'User4', '--lan-channel-number', '1']).returns(<<~SECTION)
        Username                                      NEWUSER
      SECTION
      provider.expects(:bmcconfig_exec)
              .with(['--commit', '--key-pair', 'User4:Lan_Privilege_Limit=Operator', '--lan-channel-number', '1'], sensitive: false)

      provider.priv = 3
    end

    it 'refuses to set privilege when the slot owner does not match' do
      provider.expects(:bmcconfig_exec).with(['--checkout', '--section', 'User4', '--lan-channel-number', '1']).returns(<<~SECTION)
        Username                                      SLAM
      SECTION

      expect { provider.priv = 3 }.to raise_error(%r{Refusing to modify slot 4: expected user 'NEWUSER' but slot contains "SLAM"})
    end
  end

  describe '#bmcconfig_exec' do
    let(:provider) { resource_for(4).provider }

    it 'passes an argv array that fails on error, keeps stderr and is redacted' do
      Puppet::Util::Execution.unstub(:execute)
      argv = ['/usr/sbin/bmc-config', '--commit', '--key-pair', 'User4:Password=pw', '--lan-channel-number', '1']
      options = { failonfail: true, combine: true, sensitive: true }
      Puppet::Util::Execution.expects(:execute).with(argv, options).returns(Puppet::Util::Execution::ProcessOutput.new('', 0))

      provider.bmcconfig_exec(['--commit', '--key-pair', 'User4:Password=pw', '--lan-channel-number', '1'], sensitive: true)
    end
  end

  describe 'user section caching' do
    let(:provider) { resource_for(4).provider }

    it 'checks out User4 only once per provider instance' do
      provider.expects(:bmcconfig_exec)
              .with(['--checkout', '--section', 'User4', '--lan-channel-number', '1'])
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
              .with(['--checkout', '--section', 'User4', '--lan-channel-number', '1'])
              .returns(<<~SECTION)
                Username                                      NEWUSER
                Enable_User                                   Yes
                Lan_Privilege_Limit                           Administrator
              SECTION
              .twice
      provider.expects(:bmcconfig_exec)
              .with(['--commit', '--key-pair', 'User4:Username=RENAMED', '--lan-channel-number', '1'], sensitive: false)

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
      resource.provider.stubs(:user).returns('NEWUSER')
      resource.provider.stubs(:priv).returns(4)
      resource.provider.stubs(:enable).returns(:false)
      resource.provider.stubs(:purge_id_mismatch).returns(:false)
      resource.provider.expects(:priv=).never
      resource.provider.expects(:enable=).never

      catalog.apply
    ensure
      FileUtils.rm_rf(state_dir)
    end
  end

  describe 'purge_id_mismatch property' do
    let(:provider) { type.new(base_params.merge(user_id: 4, purge_id_mismatch: :true)).provider }

    it 'returns :false when a duplicate username exists' do
      provider.expects(:bmcconfig_exec).with(['--checkout'], failonfail: false).returns(checkout_result(<<~CHECKOUT))
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
      provider.expects(:bmcconfig_exec).with(['--checkout'], failonfail: false).returns(checkout_result(supermicro_checkout))

      expect(provider.purge_id_mismatch).to eq(:true)
    end

    it 'returns :true without checking slots when purge_id_mismatch is false' do
      provider.resource[:purge_id_mismatch] = :false
      provider.expects(:bmcconfig_exec).never

      expect(provider.purge_id_mismatch).to eq(:true)
    end

    it 'purges duplicate slots' do
      provider.expects(:bmcconfig_exec).with(['--checkout'], failonfail: false).returns(checkout_result(<<~CHECKOUT)).at_least_once
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
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User2:Username=DISABLED_2', '--lan-channel-number', '1'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User2:Enable_User=No', '--lan-channel-number', '1'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User2:Lan_Privilege_Limit=No_Access', '--lan-channel-number', '1'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User2:Lan_Enable_IPMI_Msgs=No', '--lan-channel-number', '1'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User2:Lan_Enable_Link_Auth=No', '--lan-channel-number', '1'], sensitive: false)
      provider.expects(:bmcconfig_exec).with(['--commit', '--key-pair', 'User2:SOL_Payload_Access=No', '--lan-channel-number', '1'], sensitive: false)

      provider.purge_id_mismatch = :true
    end
  end

  describe '#parse_section' do
    let(:provider) { resource_for(4).provider }

    it 'parses a key with whitespace in the value' do
      output = <<~SECTION
        Section User4
        Username                                      NEWUSER
        Community_String                              my community
        EndSection
      SECTION

      expect(provider.send(:parse_section, output)).to eq(
        'Username' => 'NEWUSER',
        'Community_String' => 'my community',
      )
    end
  end
end
