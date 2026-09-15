# frozen_string_literal: true

require 'spec_helper'
require 'puppet/type/ipmi_user'
require 'tempfile'
require 'fileutils'

describe Puppet::Type.type(:ipmi_user).provider(:ipmitool) do
  let(:type) { Puppet::Type.type(:ipmi_user) }
  let(:base_params) do
    {
      name: 'test',
      user: 'NEWUSER',
      password: 'secret',
      channel: 1,
      provider: 'ipmitool',
    }
  end
  let(:asus_list) do
    File.read('spec/fixtures/unit/puppet/provider/ipmi_user/ipmitool_user_list_asus.txt')
  end
  let(:supermicro_list) do
    File.read('spec/fixtures/unit/puppet/provider/ipmi_user/ipmitool_user_list_supermicro.txt')
  end

  before do
    Puppet::Provider::Ipmi.reset_auto_allocated_user_ids!
    described_class.stubs(:suitable?).returns(true)
    Puppet::Util::Execution.expects(:execute).never
  end

  it_behaves_like 'command-confined provider', :ipmitool

  def resource_for(user_id)
    type.new(base_params.merge(user_id: user_id))
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

      slam_provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(asus_list)

      expect(slam_provider.resolved_user_id).to eq(4)
    end

    it 'selects the lowest free slot, skipping id 1' do
      provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(supermicro_list)

      expect(provider.resolved_user_id).to eq(3)
    end

    it 'treats DISABLED_* slots as free' do
      disabled_list = asus_list.gsub('Administrator', 'DISABLED_5')

      provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(disabled_list)

      expect(provider.resolved_user_id).to eq(5)
    end

    it 'falls back to a maximum of 15 when the user list is empty' do
      provider.expects(:ipmitool_exec).with(%w[user list 1]).returns('')

      expect(provider.resolved_user_id).to eq(2)
    end

    it 'never resolves auto to slot 1, even when slot 1 holds the requested name' do
      list = "ID  Name             Callin  Link Auth  IPMI Msg   Channel Priv Limit\n" \
             "1   NEWUSER          true    true       true       ADMINISTRATOR\n" \
             "2   ADMIN            true    true       true       ADMINISTRATOR\n" \
             "3                    true    false      false      Unknown (0x00)\n"
      provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(list)

      expect(provider.resolved_user_id).to eq(3)
    end

    it 'raises when no free slot is available' do
      full_list = "ID  Name             Callin  Link Auth  IPMI Msg   Channel Priv Limit\n"
      (2..15).each do |id|
        full_list += "#{id}   user#{id}            true    true       true       ADMINISTRATOR\n"
      end

      provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(full_list)

      expect { provider.resolved_user_id }.to raise_error(Puppet::Error, %r{No free IPMI user slot})
    end

    it 'raises when the user list command fails' do
      result = Puppet::Util::Execution::ProcessOutput.new('Unable to establish LAN session', 1)
      provider.expects(:ipmitool_exec).with(%w[user list 1]).raises(Puppet::ExecutionFailure, result)

      expect { provider.resolved_user_id }.to raise_error(Puppet::ExecutionFailure)
    end

    it 'allocates distinct ids for multiple auto resources' do
      resource_a = type.new(base_params.merge(name: 'a', user: 'A', user_id: 'auto'))
      resource_b = type.new(base_params.merge(name: 'b', user: 'B', user_id: 'auto'))
      provider_a = resource_a.provider
      provider_b = resource_b.provider

      provider_a.expects(:ipmitool_exec).with(%w[user list 1]).returns(supermicro_list)
      provider_b.expects(:ipmitool_exec).with(%w[user list 1]).returns(supermicro_list)

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

      auto_provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(supermicro_list)

      expect(auto_provider.resolved_user_id).not_to eq(3)
    end
  end

  describe '#find_user_by_id' do
    let(:provider) { resource_for(4).provider }

    it 'returns the matching user hash' do
      provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(asus_list)

      entry = provider.find_user_by_id(4)
      expect(entry).to eq({ id: 4, name: 'SLAM', privilege: 'ADMINISTRATOR' })
    end

    it 'returns nil when the id is not present' do
      provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(supermicro_list)

      expect(provider.find_user_by_id(99)).to be_nil
    end
  end

  describe 'user property' do
    let(:provider) { resource_for(4).provider }

    it 'returns the current username from the BMC' do
      provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(asus_list)

      expect(provider.user).to eq('SLAM')
    end

    it 'returns an empty string when the slot is empty' do
      provider_empty = resource_for(3).provider
      provider_empty.expects(:ipmitool_exec).with(%w[user list 1]).returns(supermicro_list)

      expect(provider_empty.user).to eq('')
    end

    it 'sets the username' do
      provider.expects(:ipmitool_exec).with(%w[user set name 4 NEWUSER])

      provider.user = 'NEWUSER'
    end
  end

  describe 'password property' do
    let(:provider) { resource_for(4).provider }

    it 'reports :absent as the current value' do
      expect(provider.password).to eq(:absent)
    end

    it 'tests 16-byte passwords with ipmitool user test' do
      provider.expects(:ipmitool_exec)
              .with(['user', 'test', '4', '16', 'secret'], sensitive: true, failonfail: false)
              .returns(stub('result', exitstatus: 0))

      expect(provider.password_insync?).to be(true)
    end

    it 'tests 20-byte form when a 16-byte password is stored that way' do
      provider.expects(:ipmitool_exec)
              .with(['user', 'test', '4', '16', 'secret'], sensitive: true, failonfail: false)
              .returns(stub('result', exitstatus: 1))
      provider.expects(:ipmitool_exec)
              .with(['user', 'test', '4', '20', 'secret'], sensitive: true, failonfail: false)
              .returns(stub('result', exitstatus: 0))

      expect(provider.password_insync?).to be(true)
    end

    it 'tests 20-byte passwords with ipmitool user test' do
      provider.resource[:password] = 's' * 17
      provider.expects(:ipmitool_exec)
              .with(['user', 'test', '4', '20', 's' * 17], sensitive: true, failonfail: false)
              .returns(stub('result', exitstatus: 1))

      expect(provider.password_insync?).to be(false)
    end

    it 'sets the password with 16-byte capacity' do
      provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(<<~LIST)
        ID  Name             Callin  Link Auth  IPMI Msg   Channel Priv Limit
        1                    true    false      false      Unknown (0x00)
        2   ADMIN            true    true       true       ADMINISTRATOR
        3                    true    false      false      Unknown (0x00)
        4   NEWUSER          true    true       true       ADMINISTRATOR
      LIST
      provider.expects(:ipmitool_exec)
              .with(%w[user set password 4 secret 16], sensitive: true)

      provider.password = 'secret'
    end

    it 'sets the password with 20-byte capacity' do
      provider.resource[:password] = 's' * 17
      provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(<<~LIST)
        ID  Name             Callin  Link Auth  IPMI Msg   Channel Priv Limit
        1                    true    false      false      Unknown (0x00)
        2   ADMIN            true    true       true       ADMINISTRATOR
        3                    true    false      false      Unknown (0x00)
        4   NEWUSER          true    true       true       ADMINISTRATOR
      LIST
      provider.expects(:ipmitool_exec)
              .with(%w[user set password 4 sssssssssssssssss 20], sensitive: true)

      provider.password = 's' * 17
    end

    it 'refuses to set the password when the slot owner does not match' do
      provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(asus_list)

      expect { provider.password = 'secret' }.to raise_error(%r{Refusing to modify slot 4: expected user 'NEWUSER' but slot contains "SLAM"})
    end

    it 'does not set the password when enable is false' do
      provider.resource[:enable] = :false
      provider.expects(:ipmitool_exec).never

      provider.password = 'secret'
    end

    it 'reports the password as in sync when enable is false' do
      provider.resource[:enable] = :false
      provider.expects(:ipmitool_exec).never

      expect(provider.password_insync?).to be(true)
    end

    it 'unwraps Sensitive passwords' do
      provider.resource[:password] = Puppet::Pops::Types::PSensitiveType::Sensitive.new('secret')
      provider.expects(:ipmitool_exec)
              .with(['user', 'test', '4', '16', 'secret'], sensitive: true, failonfail: false)
              .returns(stub('result', exitstatus: 0))

      expect(provider.password_insync?).to be(true)
    end
  end

  describe 'enable property' do
    let(:provider) { resource_for(4).provider }

    it 'is false when privilege is NO ACCESS' do
      list = asus_list.gsub('ADMINISTRATOR', 'NO ACCESS')
      provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(list)

      expect(provider.enable).to eq(:false)
    end

    it 'is false when the slot has no username' do
      provider_empty = resource_for(3).provider
      provider_empty.expects(:ipmitool_exec).with(%w[user list 1]).returns(supermicro_list)

      expect(provider_empty.enable).to eq(:false)
    end

    it 'is true when the slot is enabled' do
      provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(asus_list)
      provider.expects(:ipmitool_exec).with(%w[channel getaccess 1 4]).returns(<<~ACCESS)
        User ID              : 4
        User Name            : SLAM
        Enable Status        : enabled
        Privilege Level      : ADMINISTRATOR
      ACCESS

      expect(provider.enable).to eq(:true)
    end

    it 'checks getaccess for a nameless slot when disabling' do
      provider_empty = resource_for(3).provider
      provider_empty.resource[:enable] = :false
      provider_empty.expects(:ipmitool_exec).with(%w[user list 1]).returns(supermicro_list)
      provider_empty.expects(:ipmitool_exec).with(%w[channel getaccess 1 3]).returns(<<~ACCESS)
        User ID              : 3
        User Name            :
        Enable Status        : enabled
        Privilege Level      : Unknown (0x00)
      ACCESS

      expect(provider_empty.enable).to eq(:true)
    end

    it 'enables a user' do
      provider.expects(:ipmitool_exec).with(%w[user set name 4 NEWUSER])
      provider.expects(:ipmitool_exec).with(%w[user set password 4 secret 16], sensitive: true)
      provider.expects(:ipmitool_exec).with(%w[user priv 4 4 1])
      provider.expects(:ipmitool_exec).with(%w[user enable 4])
      provider.expects(:ipmitool_exec).with(%w[sol payload enable 1 4])
      provider.expects(:ipmitool_exec)
              .with(%w[channel setaccess 1 4 callin=on ipmi=on link=on privilege=4])

      provider.enable = :true
    end

    it 'disables a user' do
      provider.expects(:ipmitool_exec).with(%w[user priv 4 0xF 1])
      provider.expects(:ipmitool_exec).with(%w[user disable 4])
      provider.expects(:ipmitool_exec).with(%w[sol payload disable 1 4])
      provider.expects(:ipmitool_exec)
              .with(%w[channel setaccess 1 4 callin=off ipmi=off link=off privilege=15])

      provider.enable = :false
    end
  end

  describe 'priv property' do
    let(:provider) { resource_for(4).provider }

    it 'returns the numeric privilege level' do
      provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(asus_list)

      expect(provider.priv).to eq(4)
    end

    it 'sets privilege and channel access' do
      provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(<<~LIST)
        ID  Name             Callin  Link Auth  IPMI Msg   Channel Priv Limit
        1                    true    false      false      Unknown (0x00)
        2   ADMIN            true    true       true       ADMINISTRATOR
        3                    true    false      false      Unknown (0x00)
        4   NEWUSER          true    true       true       ADMINISTRATOR
      LIST
      provider.expects(:ipmitool_exec).with(%w[user priv 4 3 1])
      provider.expects(:ipmitool_exec)
              .with(%w[channel setaccess 1 4 callin=on ipmi=on link=on privilege=3])

      provider.priv = 3
    end

    it 'refuses to set privilege when the slot owner does not match' do
      provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(asus_list)

      expect { provider.priv = 3 }.to raise_error(%r{Refusing to modify slot 4: expected user 'NEWUSER' but slot contains "SLAM"})
    end
  end

  describe '#ipmitool_exec' do
    let(:provider) { resource_for(4).provider }

    it 'passes an argv array that fails on error, keeps stderr and is redacted' do
      Puppet::Util::Execution.unstub(:execute)
      argv = ['/usr/bin/ipmitool', 'user', 'set', 'password', '4', 'pw', '16']
      options = { failonfail: true, combine: true, sensitive: true }
      Puppet::Util::Execution.expects(:execute).with(argv, options).returns(Puppet::Util::Execution::ProcessOutput.new('', 0))

      provider.ipmitool_exec(%w[user set password 4 pw 16], sensitive: true)
    end
  end

  describe 'private helpers' do
    let(:provider) { resource_for(4).provider }

    it '#enable_user! sets name, password, privilege, and enables the slot' do
      provider.expects(:ipmitool_exec).with(%w[user set name 4 NEWUSER])
      provider.expects(:ipmitool_exec).with(%w[user set password 4 secret 16], sensitive: true)
      provider.expects(:ipmitool_exec).with(%w[user priv 4 4 1])
      provider.expects(:ipmitool_exec).with(%w[user enable 4])
      provider.expects(:ipmitool_exec).with(%w[sol payload enable 1 4])
      provider.expects(:ipmitool_exec)
              .with(%w[channel setaccess 1 4 callin=on ipmi=on link=on privilege=4])

      provider.send(:enable_user!)
    end

    it '#disable_user! removes privileges and disables the slot' do
      provider.expects(:ipmitool_exec).with(%w[user priv 4 0xF 1])
      provider.expects(:ipmitool_exec).with(%w[user disable 4])
      provider.expects(:ipmitool_exec).with(%w[sol payload disable 1 4])
      provider.expects(:ipmitool_exec)
              .with(%w[channel setaccess 1 4 callin=off ipmi=off link=off privilege=15])

      provider.send(:disable_user!)
    end

    it '#purge_mismatched_ids! blanks and disables duplicate slots' do
      duplicate_list = <<~LIST
        ID  Name             Callin  Link Auth  IPMI Msg   Channel Priv Limit
        1                    true    false      false      Unknown (0x00)
        2   NEWUSER          true    true       true       ADMINISTRATOR
        3                    true    false      false      Unknown (0x00)
        4   NEWUSER          true    true       true       ADMINISTRATOR
      LIST

      provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(duplicate_list).at_least_once
      provider.expects(:ipmitool_exec).with(%w[user set name 2 DISABLED_2])
      provider.expects(:ipmitool_exec).with(%w[user disable 2])
      provider.expects(:ipmitool_exec)
              .with(%w[channel setaccess 1 2 callin=off ipmi=off link=off privilege=15])

      provider.send(:purge_mismatched_ids!)
    end
  end

  describe 'user list caching' do
    let(:provider) { resource_for(4).provider }

    it 'calls ipmitool user list only once per provider instance' do
      provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(asus_list).once
      provider.expects(:ipmitool_exec).with(%w[channel getaccess 1 4]).returns(<<~ACCESS)
        User ID              : 4
        User Name            : SLAM
        Enable Status        : enabled
        Privilege Level      : ADMINISTRATOR
      ACCESS

      provider.enable
      provider.priv
      provider.user
    end

    it 'invalidates the cache after a write' do
      provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(asus_list).twice
      provider.expects(:ipmitool_exec).with(%w[user set name 4 NEWNAME])

      provider.user
      provider.user = 'NEWNAME'
      provider.user
    end
  end

  describe 'when the resource is disabled' do
    it 'does not rename the slot or purge duplicates' do
      state_dir = Dir.mktmpdir
      Puppet[:statedir] = state_dir

      initial_list = <<~LIST
        ID  Name             Callin  Link Auth  IPMI Msg   Channel Priv Limit
        1                    true    false      false      Unknown (0x00)
        2   ADMIN            true    true       true       ADMINISTRATOR
        3   root             true    true       true       ADMINISTRATOR
      LIST

      resource = type.new(
        name: 'factory_admin',
        user_id: 2,
        channel: 1,
        enable: :false,
        purge_id_mismatch: :true,
        provider: 'ipmitool',
      )
      catalog = Puppet::Resource::Catalog.new
      catalog.add_resource(resource)

      resource.provider.stubs(:user).returns('ADMIN')
      resource.provider.stubs(:purge_id_mismatch).returns(:false)
      resource.provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(initial_list).at_least_once
      resource.provider.expects(:ipmitool_exec).with(%w[channel getaccess 1 2]).returns(<<~ACCESS)
        User ID              : 2
        User Name            : ADMIN
        Enable Status        : enabled
        Privilege Level      : ADMINISTRATOR
      ACCESS
      resource.provider.expects(:ipmitool_exec).with(%w[user priv 2 0xF 1])
      resource.provider.expects(:ipmitool_exec).with(%w[user disable 2])
      resource.provider.expects(:ipmitool_exec).with(%w[sol payload disable 1 2])
      resource.provider.expects(:ipmitool_exec)
              .with(%w[channel setaccess 1 2 callin=off ipmi=off link=off privilege=15])
      resource.provider.expects(:ipmitool_exec).with(%w[user set name 2 root]).never

      catalog.apply
    ensure
      FileUtils.rm_rf(state_dir)
    end

    it 'does not purge a live duplicate when disabling a slot' do
      state_dir = Dir.mktmpdir
      Puppet[:statedir] = state_dir

      initial_list = <<~LIST
        ID  Name             Callin  Link Auth  IPMI Msg   Channel Priv Limit
        1                    true    false      false      Unknown (0x00)
        2   ADMIN            true    true       true       ADMINISTRATOR
        4   SLAM             true    true       true       ADMINISTRATOR
        7   SLAM             true    true       true       ADMINISTRATOR
      LIST

      resource = type.new(
        name: 'slam_old_slot',
        user: 'SLAM',
        user_id: 7,
        channel: 1,
        enable: :false,
        purge_id_mismatch: :true,
        provider: 'ipmitool',
      )
      catalog = Puppet::Resource::Catalog.new
      catalog.add_resource(resource)

      resource.provider.stubs(:user).returns('SLAM')
      resource.provider.stubs(:purge_id_mismatch).returns(:false)
      resource.provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(initial_list).at_least_once
      resource.provider.expects(:ipmitool_exec).with(%w[channel getaccess 1 7]).returns(<<~ACCESS)
        User ID              : 7
        User Name            : SLAM
        Enable Status        : enabled
        Privilege Level      : ADMINISTRATOR
      ACCESS
      resource.provider.expects(:ipmitool_exec).with(%w[user priv 7 0xF 1])
      resource.provider.expects(:ipmitool_exec).with(%w[user disable 7])
      resource.provider.expects(:ipmitool_exec).with(%w[sol payload disable 1 7])
      resource.provider.expects(:ipmitool_exec)
              .with(%w[channel setaccess 1 7 callin=off ipmi=off link=off privilege=15])

      # Slot 4 holds the live SLAM account and must not be purged.
      resource.provider.expects(:ipmitool_exec).with(%w[user set name 4 DISABLED_4]).never
      resource.provider.expects(:ipmitool_exec).with(%w[user disable 4]).never

      catalog.apply
    ensure
      FileUtils.rm_rf(state_dir)
    end

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
        provider: 'ipmitool',
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

  describe 'when purge_id_mismatch is true' do
    it 'converges a hardening pair without destroying the admin slot' do
      state_dir = Dir.mktmpdir
      Puppet[:statedir] = state_dir

      initial_list = <<~LIST
        ID  Name             Callin  Link Auth  IPMI Msg   Channel Priv Limit
        1                    true    false      false      Unknown (0x00)
        2   ADMIN            true    true       true       ADMINISTRATOR
        3   root             true    true       true       ADMINISTRATOR
      LIST

      root_resource = type.new(
        name: 'root',
        user: 'root',
        password: 'secret',
        user_id: 3,
        channel: 1,
        enable: :true,
        priv: 4,
        purge_id_mismatch: :true,
        provider: 'ipmitool',
      )
      disable_resource = type.new(
        name: 'factory_admin',
        user_id: 2,
        channel: 1,
        enable: :false,
        purge_id_mismatch: :true,
        provider: 'ipmitool',
      )
      catalog = Puppet::Resource::Catalog.new
      catalog.add_resource(root_resource)
      catalog.add_resource(disable_resource)

      # Both resources share the same user list cache via the provider base.
      root_resource.provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(initial_list).at_least_once
      disable_resource.provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(initial_list).at_least_once

      # root resource is already correct; only verify its password to avoid changes.
      root_resource.provider.expects(:ipmitool_exec)
              .with(['user', 'test', '3', '16', 'secret'], sensitive: true, failonfail: false)
              .returns(stub('result', exitstatus: 0))
      root_resource.provider.expects(:ipmitool_exec).with(%w[channel getaccess 1 3]).returns(<<~ACCESS)
        User ID              : 3
        User Name            : root
        Enable Status        : enabled
        Privilege Level      : ADMINISTRATOR
      ACCESS

      # slot 2 should be disabled but never renamed to root.
      disable_resource.provider.expects(:ipmitool_exec).with(%w[user set name 2 root]).never
      disable_resource.provider.expects(:ipmitool_exec).with(%w[channel getaccess 1 2]).returns(<<~ACCESS)
        User ID              : 2
        User Name            : ADMIN
        Enable Status        : enabled
        Privilege Level      : ADMINISTRATOR
      ACCESS
      disable_resource.provider.expects(:ipmitool_exec).with(%w[user priv 2 0xF 1])
      disable_resource.provider.expects(:ipmitool_exec).with(%w[user disable 2])
      disable_resource.provider.expects(:ipmitool_exec).with(%w[sol payload disable 1 2])
      disable_resource.provider.expects(:ipmitool_exec)
              .with(%w[channel setaccess 1 2 callin=off ipmi=off link=off privilege=15])

      # slot 3 must not be purged because slot 2 keeps the name ADMIN.
      root_resource.provider.expects(:ipmitool_exec).with(%w[user set name 3 DISABLED_3]).never
      root_resource.provider.expects(:ipmitool_exec).with(%w[user disable 3]).never

      catalog.apply
    ensure
      FileUtils.rm_rf(state_dir)
    end

    it 'syncs purge even when enable and priv are already in sync' do
      state_dir = Dir.mktmpdir
      Puppet[:statedir] = state_dir

      resource = type.new(
        name: 'test',
        user: 'NEWUSER',
        user_id: 4,
        channel: 1,
        password: 'secret',
        enable: :true,
        priv: 4,
        purge_id_mismatch: :true,
        provider: 'ipmitool',
      )
      catalog = Puppet::Resource::Catalog.new
      catalog.add_resource(resource)
      resource.provider.stubs(:priv).returns(4)
      resource.provider.stubs(:enable).returns(:true)
      resource.provider.stubs(:user).returns('NEWUSER')
      resource.provider.stubs(:password_insync?).returns(true)
      resource.provider.expects(:purge_id_mismatch).returns(:false)
      resource.provider.expects(:purge_id_mismatch=)

      catalog.apply
    ensure
      FileUtils.rm_rf(state_dir)
    end

    it 'purges a duplicate slot through a real transaction' do
      state_dir = Dir.mktmpdir
      Puppet[:statedir] = state_dir

      duplicate_list = <<~LIST
        ID  Name             Callin  Link Auth  IPMI Msg   Channel Priv Limit
        1                    true    false      false      Unknown (0x00)
        2   ADMIN            true    true       true       ADMINISTRATOR
        3                    true    false      false      Unknown (0x00)
        4   SLAM             true    true       true       ADMINISTRATOR
        5                    true    false      false      Unknown (0x00)
        6                    true    false      false      Unknown (0x00)
        7   SLAM             true    true       true       ADMINISTRATOR
      LIST

      resource = type.new(
        name: 'test',
        user: 'SLAM',
        password: 'secret',
        user_id: 4,
        channel: 1,
        enable: :true,
        priv: 4,
        purge_id_mismatch: :true,
        provider: 'ipmitool',
      )
      catalog = Puppet::Resource::Catalog.new
      catalog.add_resource(resource)

      resource.provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(duplicate_list).at_least_once
      resource.provider.expects(:ipmitool_exec).with(['user', 'test', '4', '16', 'secret'], sensitive: true, failonfail: false).returns(stub('result', exitstatus: 0))
      resource.provider.expects(:ipmitool_exec).with(%w[channel getaccess 1 4]).returns(<<~ACCESS)
        User ID              : 4
        User Name            : SLAM
        Enable Status        : enabled
        Privilege Level      : ADMINISTRATOR
      ACCESS
      resource.provider.expects(:ipmitool_exec).with(%w[user set name 7 DISABLED_7])
      resource.provider.expects(:ipmitool_exec).with(%w[user disable 7])
      resource.provider.expects(:ipmitool_exec)
              .with(%w[channel setaccess 1 7 callin=off ipmi=off link=off privilege=15])

      catalog.apply
    ensure
      FileUtils.rm_rf(state_dir)
    end

    it 'purges a duplicate slot when user_id is auto' do
      state_dir = Dir.mktmpdir
      Puppet[:statedir] = state_dir

      duplicate_list = <<~LIST
        ID  Name             Callin  Link Auth  IPMI Msg   Channel Priv Limit
        1                    true    false      false      Unknown (0x00)
        2   ADMIN            true    true       true       ADMINISTRATOR
        3                    true    false      false      Unknown (0x00)
        4   SLAM             true    true       true       ADMINISTRATOR
        5                    true    false      false      Unknown (0x00)
        6                    true    false      false      Unknown (0x00)
        7   SLAM             true    true       true       ADMINISTRATOR
      LIST

      resource = type.new(
        name: 'test',
        user: 'SLAM',
        password: 'secret',
        user_id: 'auto',
        channel: 1,
        enable: :true,
        priv: 4,
        purge_id_mismatch: :true,
        provider: 'ipmitool',
      )
      catalog = Puppet::Resource::Catalog.new
      catalog.add_resource(resource)

      resource.provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(duplicate_list).at_least_once
      resource.provider.expects(:ipmitool_exec).with(['user', 'test', '4', '16', 'secret'], sensitive: true, failonfail: false).returns(stub('result', exitstatus: 0))
      resource.provider.expects(:ipmitool_exec).with(%w[channel getaccess 1 4]).returns(<<~ACCESS)
        User ID              : 4
        User Name            : SLAM
        Enable Status        : enabled
        Privilege Level      : ADMINISTRATOR
      ACCESS
      resource.provider.expects(:ipmitool_exec).with(%w[user set name 7 DISABLED_7])
      resource.provider.expects(:ipmitool_exec).with(%w[user disable 7])
      resource.provider.expects(:ipmitool_exec)
              .with(%w[channel setaccess 1 7 callin=off ipmi=off link=off privilege=15])

      catalog.apply
    ensure
      FileUtils.rm_rf(state_dir)
    end
  end

  describe 'purge_id_mismatch property' do
    let(:provider) { type.new(base_params.merge(user_id: 4, purge_id_mismatch: :true)).provider }

    it 'returns :false when a duplicate username exists' do
      duplicate_list = <<~LIST
        ID  Name             Callin  Link Auth  IPMI Msg   Channel Priv Limit
        1                    true    false      false      Unknown (0x00)
        2   NEWUSER          true    true       true       ADMINISTRATOR
        3                    true    false      false      Unknown (0x00)
        4   NEWUSER          true    true       true       ADMINISTRATOR
      LIST

      provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(duplicate_list)

      expect(provider.purge_id_mismatch).to eq(:false)
    end

    it 'returns :true when no duplicate username exists' do
      provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(supermicro_list)

      expect(provider.purge_id_mismatch).to eq(:true)
    end

    it 'returns :true without checking slots when purge_id_mismatch is false' do
      provider.resource[:purge_id_mismatch] = :false
      provider.expects(:ipmitool_exec).never

      expect(provider.purge_id_mismatch).to eq(:true)
    end

    it 'purges duplicate slots' do
      duplicate_list = <<~LIST
        ID  Name             Callin  Link Auth  IPMI Msg   Channel Priv Limit
        1                    true    false      false      Unknown (0x00)
        2   NEWUSER          true    true       true       ADMINISTRATOR
        3                    true    false      false      Unknown (0x00)
        4   NEWUSER          true    true       true       ADMINISTRATOR
      LIST

      provider.expects(:ipmitool_exec).with(%w[user list 1]).returns(duplicate_list).at_least_once
      provider.expects(:ipmitool_exec).with(%w[user set name 2 DISABLED_2])
      provider.expects(:ipmitool_exec).with(%w[user disable 2])
      provider.expects(:ipmitool_exec)
              .with(%w[channel setaccess 1 2 callin=off ipmi=off link=off privilege=15])

      provider.purge_id_mismatch = :true
    end
  end
end
