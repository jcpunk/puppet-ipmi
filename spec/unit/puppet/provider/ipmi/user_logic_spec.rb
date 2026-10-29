# frozen_string_literal: true

require 'spec_helper'
require 'puppet/provider/ipmi/user_logic'

describe Puppet::Provider::Ipmi::UserLogic do
  let(:table) do
    FakeUserBmc.table_with(
      { id: 1 },
      { id: 2, name: 'ADMIN', priv: 4, enabled: true },
      { id: 3 },
      { id: 4, name: 'DISABLED_4' },
    )
  end
  let(:log) { [] }
  let(:provider_class) { FakeUserBmc.provider_class(table, log, password: 'secret') }
  let(:params) do
    { name: 'bob', username: 'bob', password: 'secret', priv: 4, enable: :true, channel: 1, user_id: 3, purge_id_mismatch: :false }
  end
  let(:provider) { provider_class.provider_for(params, provider_class.read_users(1)) }

  before { Puppet::Provider::Ipmi.reset_auto_allocated_user_ids! }

  describe '.existing_slot' do
    it 'matches an explicit id only when the slot holds the username' do
      expect(described_class.existing_slot(table, 'ADMIN', 2)).to include(id: 2)
      expect(described_class.existing_slot(table, 'ADMIN', 3)).to be_nil
    end

    it 'matches the lowest id holding the username for :auto' do
      table[2][:name] = 'ADMIN'
      expect(described_class.existing_slot(table, 'ADMIN', :auto)[:id]).to eq(2)
    end

    it 'never matches the anonymous slot for :auto' do
      table[0][:name] = 'anon'
      expect(described_class.existing_slot(table, 'anon', :auto)).to be_nil
    end
  end

  describe '.instances' do
    it 'returns one provider per named slot, skipping empty and DISABLED_ slots' do
      Facter.stubs(:value).with('ipmi.default.channel').returns(nil)
      instances = provider_class.instances

      expect(instances.map(&:name)).to eq(['ADMIN'])
      expect(instances.first.priv).to eq(4)
      expect(instances.first.enable).to eq(:true)
      expect(instances.first).to be_exists
    end
  end

  describe '.prefetch' do
    it 'reads each channel once and binds a provider to every resource' do
      provider_class.expects(:read_users).with(1).once.returns(table)
      a = Struct.new(:data, :provider) do
        def [](key) = data[key]
      end
      one = a.new(params.merge(user_id: 2, username: 'ADMIN'))
      two = a.new(params.merge(name: 'amy', username: 'amy', user_id: 3))

      provider_class.prefetch('ADMIN' => one, 'amy' => two)

      expect(one.provider).to be_exists
      expect(two.provider).not_to be_exists
    end
  end

  describe 'ensure' do
    it 'exists when the slot holds the username' do
      params[:user_id] = 2
      params[:username] = 'ADMIN'
      expect(provider).to be_exists
    end

    it 'does not exist when the explicit slot holds another name' do
      params[:user_id] = 2
      expect(provider).not_to be_exists
    end

    it 'exists for :auto when any slot holds the username' do
      table[2][:name] = 'bob'
      params[:user_id] = :auto
      expect(provider).to be_exists
    end

    it 'does not allocate a slot for an absent :auto user' do
      params[:user_id] = :auto
      expect(provider).not_to be_exists
      expect(Puppet::Provider::Ipmi.auto_allocated_user_ids).to be_empty
    end

    it 'destroy blanks the slot and revokes access' do
      params[:user_id] = 2
      params[:username] = 'ADMIN'
      provider.destroy

      expect(log).to eq([[:name, 2, 'DISABLED_2'], [:access, 2, false, 15]])
    end

    it 'destroy leaves the slot free for reallocation' do
      params[:user_id] = 2
      params[:username] = 'ADMIN'
      provider.destroy

      expect(described_class.free_name?(table[1][:name])).to be(true)
    end
  end

  describe 'getters' do
    it 'reports privilege and enable from the prefetched entry' do
      params[:user_id] = 2
      params[:username] = 'ADMIN'

      expect(provider.priv).to eq(4)
      expect(provider.enable).to eq(:true)
    end

    it 'reports a named slot without access as disabled' do
      table[2][:name] = 'bob'
      expect(provider.enable).to eq(:false)
      expect(provider).to be_access_revoked
    end

    it 'reports a named, privileged slot whose enabled flag is off as disabled and not revoked' do
      table[2].merge!(name: 'bob', priv: 4)
      expect(provider.enable).to eq(:false)
      expect(provider).not_to be_access_revoked
    end

    it 'reads the table once per run' do
      provider_class.expects(:read_users).once.returns(table)
      p = provider_class.provider_for(params, provider_class.read_users(1))
      p.priv
      p.enable
      p.exists?
    end
  end

  describe '#create' do
    it 'names the slot, sets the password and grants access in order' do
      provider.create

      expect(log).to eq([[:name, 3, 'bob'], [:password, 3, 'secret'], [:access, 3, true, 4]])
    end

    it 'skips the password when none is given' do
      params[:password] = nil
      provider.create

      expect(log.map(&:first)).to eq(%i[name access])
    end

    it 'unwraps Sensitive passwords' do
      params[:password] = Puppet::Pops::Types::PSensitiveType::Sensitive.new('wrapped')
      provider.create

      expect(log).to include([:password, 3, 'wrapped'])
    end

    it 'reserves the name and revokes access when the resource is disabled' do
      params[:enable] = :false
      provider.create

      expect(log).to eq([[:name, 3, 'bob'], [:access, 3, false, 15]])
    end
  end

  describe '#enable=' do
    it 'does not rename a named slot when disabling' do
      params[:user_id] = 2
      params[:username] = 'ADMIN'
      provider.enable = :false

      expect(log).to eq([[:access, 2, false, 15]])
    end

    it 'grants access when enabling' do
      table[2][:name] = 'bob'
      provider.enable = :true

      expect(log.last).to eq([:access, 3, true, 4])
    end
  end

  describe 'password' do
    it 'reports :absent' do
      expect(provider.password).to eq(:absent)
    end

    it 'is in sync when the backend confirms the password' do
      expect(provider.password_insync?).to be(true)
    end

    it 'is out of sync when the backend rejects the password' do
      params[:password] = 'other'
      expect(provider.password_insync?).to be(false)
    end

    it 'is out of sync, not an exception, when the check raises' do
      provider_class.stubs(:password_matches?).raises(Puppet::ExecutionFailure, 'boom')
      expect(provider.password_insync?).to be(false)
    end

    it 'is in sync when disabling' do
      params[:enable] = :false
      params[:password] = 'other'
      expect(provider.password_insync?).to be(true)
    end

    it 'writes the password once the slot is owned' do
      table[2][:name] = 'bob'
      provider.password = :ignored

      expect(log).to eq([[:password, 3, 'secret']])
    end

    it 'refuses to write to a slot owned by another user' do
      params[:user_id] = 2

      expect { provider.password = :ignored }.to raise_error(Puppet::Error, %r{Refusing to modify slot 2})
      expect(log).to be_empty
    end

    it 'does not write when disabling' do
      params[:enable] = :false
      provider.password = :ignored

      expect(log).to be_empty
    end
  end

  describe 'priv=' do
    it 'writes the privilege of an owned slot' do
      table[2][:name] = 'bob'
      provider.priv = 3

      expect(log).to eq([[:priv, 3, 3]])
    end

    it 'refuses to change the privilege of a slot owned by another user' do
      params[:user_id] = 2

      expect { provider.priv = 3 }.to raise_error(Puppet::Error, %r{Refusing to modify slot 2})
    end
  end

  describe 'purge_id_mismatch' do
    before do
      table[0][:name] = 'bob'
      table[1][:name] = 'bob'
      table[1][:enabled] = true
    end

    it 'reports :true when purging is not requested' do
      expect(provider.purge_id_mismatch).to eq(:true)
    end

    it 'reports :false while a duplicate exists' do
      params[:purge_id_mismatch] = :true
      expect(provider.purge_id_mismatch).to eq(:false)
    end

    it 'blanks and disables every duplicate, leaving the resolved slot alone' do
      params[:purge_id_mismatch] = :true
      params[:user_id] = 1
      provider.purge_id_mismatch = :true

      expect(log).to eq([[:name, 2, 'DISABLED_2'], [:access, 2, false, 15]])
    end

    it 'ignores slots already marked DISABLED_*' do
      params[:purge_id_mismatch] = :true
      params[:user_id] = 1
      table[1][:name] = 'DISABLED_2'
      expect(provider.purge_id_mismatch).to eq(:true)
    end

    it 'converges after purging' do
      params[:purge_id_mismatch] = :true
      params[:user_id] = 1
      provider.purge_id_mismatch = :true

      expect(provider.purge_id_mismatch).to eq(:true)
    end

    it 'purges on the run that creates the user' do
      params[:purge_id_mismatch] = :true
      params[:user_id] = 3
      provider.create

      expect(log).to include([:name, 1, 'DISABLED_1'], [:name, 2, 'DISABLED_2'])
    end
  end

  describe 'user_id => auto' do
    before { params[:user_id] = :auto }

    it 'reuses the slot of an existing user with the same name' do
      table[1][:name] = 'bob'
      expect(provider.resolved_user_id).to eq(2)
    end

    it 'selects the lowest free slot, skipping slot 1 and treating DISABLED_* as free' do
      table[2][:name] = 'taken'
      expect(provider.resolved_user_id).to eq(4)
    end

    it 'never selects slot 1 even when it holds the requested name' do
      table[0][:name] = 'bob'
      expect(provider.resolved_user_id).to eq(3)
    end

    it 'raises when no free slot is available' do
      table.each { |u| u[:name] = "user#{u[:id]}" }
      expect { provider.resolved_user_id }.to raise_error(Puppet::Error, %r{No free IPMI user slot})
    end

    it 'allocates distinct ids to multiple auto resources' do
      other = provider_class.provider_for(params.merge(name: 'amy', username: 'amy'), provider_class.read_users(1))
      expect([provider.resolved_user_id, other.resolved_user_id].uniq.size).to eq(2)
    end
  end
end
