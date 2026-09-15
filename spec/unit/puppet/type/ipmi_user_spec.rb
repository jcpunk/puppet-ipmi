# frozen_string_literal: true

require 'spec_helper'
require 'puppet/type/ipmi_user'
require 'tempfile'
require 'fileutils'

describe Puppet::Type.type(:ipmi_user) do
  describe 'when validating attributes' do
    %i[name user_id channel ipmitool_cmd bmcconfig_cmd].each do |param|
      it "has a #{param} parameter" do
        expect(described_class.attrtype(param)).to eq(:param)
      end
    end

    %i[user password enable priv purge_id_mismatch].each do |prop|
      it "has a #{prop} property" do
        expect(described_class.attrtype(prop)).to eq(:property)
      end
    end
  end

  describe 'when validating values' do
    it 'defaults user to root' do
      resource = described_class.new(name: 'test', enable: :false)
      expect(resource[:user]).to eq('root')
    end

    it 'defaults user_id to 3' do
      resource = described_class.new(name: 'test', enable: :false)
      expect(resource[:user_id]).to eq(3)
    end

    it 'defaults channel to 1' do
      resource = described_class.new(name: 'test', enable: :false)
      expect(resource[:channel]).to eq(1)
    end

    it 'defaults enable to true' do
      # enable defaults to true but requires password
      resource = described_class.new(name: 'test', password: 'secret')
      expect(resource[:enable]).to eq(:true)
    end

    it 'defaults priv to 4' do
      resource = described_class.new(name: 'test', password: 'secret')
      expect(resource[:priv]).to eq(4)
    end

    it 'rejects password over 20 characters when enable is true' do
      expect do
        described_class.new(name: 'test', password: 'a' * 21, enable: :true)
      end.to raise_error(Puppet::Error, %r{20 or fewer characters})
    end

    it 'requires password when enable is true' do
      expect do
        described_class.new(name: 'test', enable: :true)
      end.to raise_error(Puppet::Error, %r{You must supply a password})
    end

    it 'does not require password when enable is false' do
      resource = described_class.new(name: 'test', enable: :false)
      expect(resource[:enable]).to eq(:false)
    end

    it 'rejects invalid priv values when enable is true' do
      expect do
        described_class.new(name: 'test', password: 'secret', priv: 5)
      end.to raise_error(Puppet::Error, %r{priv must be})
    end

    it 'accepts invalid priv values when enable is false' do
      resource = described_class.new(name: 'test', enable: :false, priv: 5)
      expect(resource[:priv]).to eq(5)
    end

    it 'accepts valid priv values' do
      [1, 2, 3, 4].each do |p|
        resource = described_class.new(name: "test#{p}", password: 'secret', priv: p)
        expect(resource[:priv]).to eq(p)
      end
    end

    it 'ignores priv mismatch when enable is false' do
      resource = described_class.new(name: 'test', enable: :false, priv: 3)
      expect(resource.property(:priv).insync?(4)).to be(true)
    end

    it 'rejects invalid user_id' do
      expect do
        described_class.new(name: 'test', enable: :false, user_id: 0)
      end.to raise_error(Puppet::Error, %r{user_id must be a positive integer or "auto"})
    end

    it 'accepts user_id auto as a string' do
      resource = described_class.new(name: 'test', enable: :false, user_id: 'auto')
      expect(resource[:user_id]).to eq(:auto)
    end

    it 'accepts user_id auto as a symbol' do
      resource = described_class.new(name: 'test', enable: :false, user_id: :auto)
      expect(resource[:user_id]).to eq(:auto)
    end

    it 'rejects non-auto string user_id values' do
      expect do
        described_class.new(name: 'test', enable: :false, user_id: 'foo')
      end.to raise_error(Puppet::Error, %r{user_id must be a positive integer or "auto"})
    end
  end

  describe 'when handling sensitive values' do
    it 'marks the password property as sensitive' do
      resource = described_class.new(name: 'test', password: 'secret', enable: :false)

      expect(resource.parameter(:password)).to respond_to(:is_sensitive)
      expect(resource.parameter(:password).is_sensitive).to be(true)
    end

    it 'does not log the plaintext password when applying a change' do
      state_dir = Dir.mktmpdir
      Puppet[:statedir] = state_dir

      resource = described_class.new(
        name: 'test',
        user: 'NEWUSER',
        password: 'supersecret',
        user_id: 4,
        channel: 1,
        enable: :true,
        priv: 4,
        provider: 'ipmitool',
      )
      catalog = Puppet::Resource::Catalog.new
      catalog.add_resource(resource)

      resource.provider.stubs(:user).returns('NEWUSER')
      resource.provider.stubs(:priv).returns(4)
      resource.provider.stubs(:enable).returns(:true)
      resource.provider.stubs(:password_insync?).returns(false)
      resource.provider.stubs(:password=)
      resource.provider.stubs(:purge_id_mismatch).returns(:true)

      transaction = catalog.apply

      password_logs = transaction.report.logs.select do |log|
        log.source.to_s.include?('/password')
      end
      messages = password_logs.map(&:message).join("\n")

      expect(password_logs).not_to be_empty
      expect(messages).not_to include('supersecret')
      expect(messages).to include('[redacted]')
    ensure
      FileUtils.rm_rf(state_dir)
    end
  end
end
