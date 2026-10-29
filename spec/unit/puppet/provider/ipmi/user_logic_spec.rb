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
  let(:provider) { provider_class.new(params) }

  describe 'slot reads' do
    it 'reports the username of the resolved slot' do
      params[:user_id] = 2
      expect(provider.username).to eq('ADMIN')
    end

    it 'reports an empty name for an unused slot' do
      expect(provider.username).to eq('')
    end

    it 'reports nil for a slot the BMC does not have' do
      params[:user_id] = 9
      expect(provider.username).to be_nil
      expect(provider.priv).to be_nil
    end

    it 'reads the table once until a write happens' do
      provider_class.expects(:read_users).once.returns(table)
      provider.username
      provider.priv
      provider.enable
    end
  end

  describe '#enable' do
    it 'is :false for an unnamed slot' do
      expect(provider.enable).to eq(:false)
    end

    it 'is :false for a named slot without access' do
      table[2][:name] = 'bob'
      expect(provider.enable).to eq(:false)
    end

    it 'is :true for an enabled slot' do
      params[:user_id] = 2
      expect(provider.enable).to eq(:true)
    end

    it 'is :false for a named slot that is not enabled' do
      params[:user_id] = 2
      table[1][:enabled] = false
      expect(provider.enable).to eq(:false)
    end

    it 'reports a nameless slot as out of sync when disabling' do
      params[:enable] = :false
      expect(provider.enable).to eq(:true)
    end
  end

  describe '#enable=' do
    it 'names the slot, sets the password and grants access in order' do
      provider.enable = :true

      expect(log).to eq([[:name, 3, 'bob'], [:password, 3, 'secret'], [:access, 3, true, 4]])
    end

    it 'skips the password when none is given' do
      params[:password] = nil
      provider.enable = :true

      expect(log.map(&:first)).to eq(%i[name access])
    end

    it 'unwraps Sensitive passwords' do
      params[:password] = Puppet::Pops::Types::PSensitiveType::Sensitive.new('wrapped')
      provider.enable = :true

      expect(log).to include([:password, 3, 'wrapped'])
    end

    it 'names an empty slot and revokes access when disabling' do
      provider.enable = :false

      expect(log).to eq([[:name, 3, 'bob'], [:access, 3, false, 15]])
    end

    it 'does not rename a named slot when disabling' do
      params[:user_id] = 2
      provider.enable = :false

      expect(log).to eq([[:access, 2, false, 15]])
    end

    it 'is idempotent once converged' do
      provider.enable = :true
      params[:user_id] = 3

      expect(provider_class.new(params).enable).to eq(:true)
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

  describe 'priv' do
    it 'reports the numeric privilege' do
      params[:user_id] = 2
      expect(provider.priv).to eq(4)
    end

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

  describe 'username=' do
    it 'writes the name and drops the cached table' do
      provider.username = 'bob'

      expect(log).to eq([[:name, 3, 'bob']])
      expect(provider.username).to eq('bob')
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
      params[:user_id] = 3
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
  end

  describe 'user_id => auto' do
    before do
      Puppet::Provider::Ipmi.reset_auto_allocated_user_ids!
      params[:user_id] = :auto
    end

    it 'reuses the slot of an existing user with the same name' do
      table[1][:name] = 'bob'
      expect(provider.resolved_user_id).to eq(2)
    end

    it 'selects the lowest free slot, skipping slot 1 and treating DISABLED_* as free' do
      table[1][:name] = 'ADMIN'
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
      other = provider_class.new(params.merge(name: 'amy', username: 'amy'))
      expect([provider.resolved_user_id, other.resolved_user_id].uniq.size).to eq(2)
    end
  end
end
