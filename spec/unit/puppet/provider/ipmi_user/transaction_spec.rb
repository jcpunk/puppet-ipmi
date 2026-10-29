# frozen_string_literal: true

require 'spec_helper'
require 'puppet/type/ipmi_user'

# Runs real catalogs against the in-memory fake BMC to check that
# prefetch, ensure and the property setters cooperate and converge.
describe 'ipmi_user catalog application' do
  let(:type) { Puppet::Type.type(:ipmi_user) }
  let(:table) { FakeUserBmc.table_with({ id: 1 }, { id: 2, name: 'ADMIN', priv: 4, enabled: true }, { id: 3 }, { id: 4 }) }
  let(:log) { [] }
  let(:state_dir) { Dir.mktmpdir }

  let(:provider) { FakeUserBmc.registered_provider }

  before do
    Puppet[:statedir] = state_dir
    Puppet::Provider::Ipmi.reset_auto_allocated_user_ids!
    provider.stubs(:suitable?).returns(true)
    provider.fake_table = table
    provider.fake_log = log
    provider.fake_password = 'secret'
  end

  after { FileUtils.rm_rf(state_dir) }

  def apply(**params)
    resource = type.new({ name: 'bob', password: 'secret', channel: 1, provider: 'fake_bmc' }.merge(params).compact)
    catalog = Puppet::Resource::Catalog.new
    catalog.add_resource(resource)
    catalog.apply.report
  end

  def changed_count(report)
    report.resource_statuses.values.count(&:changed)
  end

  it 'creates a user on the first run and is idempotent on the second' do
    expect(changed_count(apply(user_id: 3))).to eq(1)
    expect(table.find { |u| u[:id] == 3 }).to include(name: 'bob', priv: 4, enabled: true)

    log.clear
    expect(changed_count(apply(user_id: 3))).to eq(0)
    expect(log).to be_empty
  end

  it 'allocates the lowest free slot for user_id auto' do
    apply
    expect(table.find { |u| u[:id] == 3 }[:name]).to eq('bob')
  end

  it 'converges a disabled user and then stays quiet' do
    expect(changed_count(apply(user_id: 3, enable: :false, password: nil))).to eq(1)
    expect(table.find { |u| u[:id] == 3 }).to include(name: 'bob', enabled: false, priv: 15)

    expect(changed_count(apply(user_id: 3, enable: :false, password: nil))).to eq(0)
  end

  it 'removes an existing user with ensure absent and does nothing for a missing one' do
    expect(changed_count(apply(name: 'ADMIN', user_id: 2, ensure: :absent, password: nil))).to eq(1)
    expect(table.find { |u| u[:id] == 2 }).to include(name: 'DISABLED_2', enabled: false)

    expect(changed_count(apply(name: 'ADMIN', user_id: 2, ensure: :absent, password: nil))).to eq(0)
    expect(changed_count(apply(name: 'ghost', ensure: :absent, password: nil))).to eq(0)
  end
end
