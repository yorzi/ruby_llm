# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RubyLLM::CodeExecution::RubyInstallation do
  let(:root) { Dir.mktmpdir('ruby_llm-ruby-spec') }
  let(:prefix) { File.join(root, 'ruby') }
  let(:gem_dir) { File.join(prefix, 'lib', 'ruby', 'gems', '4.0.0') }
  let(:bundle) { File.join(root, 'bundle') }
  let(:installation) { described_class.new(prefix:, gem_dir:, gem_path: [bundle, gem_dir], archdir:) }

  after { FileUtils.rm_rf(root) }

  def bundled_gems_constant?
    require 'bundled_gems'
    defined?(Gem::BUNDLED_GEMS::SINCE)
  rescue LoadError
    false
  end

  def archdir
    File.join(prefix, 'lib', 'ruby', '4.0.0', 'arm64-darwin25')
  end

  def extensions
    File.join(gem_dir, 'extensions', Gem::Platform.local.to_s, Gem.extension_api_version)
  end

  def install(name, version, default: false)
    specifications = File.join(gem_dir, 'specifications', *('default' if default))
    FileUtils.mkdir_p(specifications)
    File.write(File.join(specifications, "#{name}-#{version}.gemspec"), <<~RUBY)
      # stub: #{name} #{version} ruby lib
      Gem::Specification.new do |s|
        s.name = "#{name}"
        s.version = "#{version}"
      end
    RUBY
    FileUtils.mkdir_p(File.join(gem_dir, 'gems', "#{name}-#{version}"))
  end

  before do
    FileUtils.mkdir_p([bundle, File.join(gem_dir, 'cache'), File.join(gem_dir, 'plugins')])
    install('json', '2.10.0', default: true)
    install('json', '2.15.0')
    install('csv', '3.3.5')
    install('rspec-core', '3.13.0')
    FileUtils.mkdir_p(File.join(extensions, 'rspec-core-3.13.0'))
    File.write(File.join(extensions, 'rspec-core-3.13.0', 'gem.build_complete'), '')
    File.write(File.join(extensions, 'rspec-core-3.13.0', 'native.so'), '')
    File.write(File.join(gem_dir, 'plugins', 'rspec-core_plugin.rb'), '')
    File.write(File.join(gem_dir, 'plugins', 'csv_plugin.rb'), '')
    allow(installation).to receive(:bundled_gems).and_return(%w[csv])
  end

  it 'mounts the Ruby installation' do
    expect(installation.readable).to eq([prefix])
  end

  describe 'libraries the extensions link' do
    def cellar
      File.join(root, 'homebrew', 'Cellar', 'libyaml', '0.2.5', 'lib')
    end

    def opt
      File.join(root, 'homebrew', 'opt', 'libyaml')
    end

    before do
      FileUtils.mkdir_p([archdir, cellar, File.dirname(opt)])
      File.write(File.join(archdir, 'psych.bundle'), '')
      File.write(File.join(prefix, 'lib', 'libruby.4.0.dylib'), '')
      File.write(File.join(cellar, 'libyaml-0.2.dylib'), '')
      File.symlink(File.dirname(cellar), opt)
    end

    def otool_lists(*libraries)
      lines = libraries.map { |library| "\t#{library} (compatibility version 1.0.0, current version 1.0.0)\n" }
      allow(Open3).to receive(:capture2).with('otool', '-L', File.join(archdir, 'psych.bundle'))
                                        .and_return(["#{archdir}/psych.bundle:\n#{lines.join}", nil])
    end

    it 'mounts the real directory of a library outside the installation' do
      otool_lists(File.join(prefix, 'lib', 'libruby.4.0.dylib'), File.join(opt, 'lib', 'libyaml-0.2.dylib'),
                  '/usr/lib/libSystem.B.dylib', '/System/Library/Frameworks/Security.framework/Security')

      expect(installation.readable).to eq([prefix, File.realpath(cellar)])
    end

    it 'mounts each library directory once' do
      otool_lists(File.join(opt, 'lib', 'libyaml-0.2.dylib'), File.join(cellar, 'libyaml-0.2.dylib'))

      expect(installation.readable).to eq([prefix, File.realpath(cellar)])
    end

    it 'skips a listed library that is not on disk' do
      otool_lists(File.join(root, 'missing', 'libgone.dylib'))

      expect(installation.readable).to eq([prefix])
    end

    it 'mounts only the installation when otool is not installed' do
      allow(Open3).to receive(:capture2).and_raise(Errno::ENOENT)

      expect(installation.readable).to eq([prefix])
    end

    it 'reads the extensions once' do
      otool_lists(File.join(opt, 'lib', 'libyaml-0.2.dylib'))

      2.times { installation.readable }

      expect(Open3).to have_received(:capture2).once
    end

    it 'does not look for libraries without extension bundles' do
      FileUtils.rm(File.join(archdir, 'psych.bundle'))
      allow(Open3).to receive(:capture2)

      expect(installation.readable).to eq([prefix])
      expect(Open3).not_to have_received(:capture2)
    end
  end

  it "hides the application's gems, keeping Ruby's default and bundled gems" do
    expect(installation.denied).to contain_exactly(
      File.join(gem_dir, 'gems', 'rspec-core-3.13.0'),
      File.join(extensions, 'rspec-core-3.13.0', 'native.so'),
      File.join(gem_dir, 'plugins', 'rspec-core_plugin.rb'),
      File.join(gem_dir, 'cache'),
      bundle
    )
  end

  it "builds a gem directory with only Ruby's bundled gems, once" do
    FileUtils.mkdir_p(File.join(extensions, 'csv-3.3.5'))
    cache = File.join(root, 'cache-dir')

    view = installation.ruby_gems(cache)

    expect(Dir.children(File.join(view, 'specifications'))).to eq(['csv-3.3.5.gemspec'])
    expect(File.readlink(File.join(view, 'gems', 'csv-3.3.5'))).to eq(File.join(gem_dir, 'gems', 'csv-3.3.5'))
    expect(File.symlink?(File.join(view, extensions.delete_prefix(gem_dir), 'csv-3.3.5'))).to be(true)
    expect(Dir.exist?(File.join(view, 'gems', 'rspec-core-3.13.0'))).to be(false)
    expect(installation.ruby_gems(cache)).to eq(view)
  end

  it 'reads the bundled gems Ruby lists' do
    allow(installation).to receive(:bundled_gems).and_call_original
    allow(RbConfig::CONFIG).to receive(:[]).and_call_original
    allow(RbConfig::CONFIG).to receive(:[]).with('srcdir').and_return(root)
    FileUtils.mkdir_p(File.join(root, 'gems'))
    File.write(File.join(root, 'gems', 'bundled_gems'), "# comment\n\nminitest 5.25.0 https://example.com\ncsv 3.3.5\n")

    expect(installation.ruby_gem?('minitest')).to be(true)
    expect(installation.ruby_gem?('rspec-core')).to be(false)
  end

  it 'falls back to the gems Ruby moved from default to bundled' do
    allow(installation).to receive(:bundled_gems).and_call_original
    allow(RbConfig::CONFIG).to receive(:[]).and_call_original
    allow(RbConfig::CONFIG).to receive(:[]).with('srcdir').and_return(nil)
    skip 'this Ruby has no Gem::BUNDLED_GEMS' unless bundled_gems_constant?

    expect(installation.ruby_gem?(Gem::BUNDLED_GEMS::SINCE.keys.first)).to be(true)
  end
end
