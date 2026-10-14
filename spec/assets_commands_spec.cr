# `crails assets:*` — parity отклонения #1: таска должна видеть
# кастомный config.assets.paths (режим приложения) и env
# CRAILS_ASSETS_PATHS (оба режима). Здесь — рамочное тестирование
# общего исполнителя на готовой Assembly с кастомным load path.

require "spec"
require "../src/railties_cr"
require "file_utils"
require "json"

Propshaft.logger = IO::Memory.new # "Writing ..." — не в вывод спеков

CMD_ROOT = File.join(Dir.tempdir, "crails_assets_cmd_#{Random::Secure.hex(4)}")

def cmd_manifest_path : String
  File.join(CMD_ROOT, "public/assets/.manifest.json")
end

def cmd_output_path : String
  File.join(CMD_ROOT, "public/assets")
end

describe "CRails::AssetsCommands" do
  it "precompiles a custom load path (custom config.assets.paths)" do
    theme = File.join(CMD_ROOT, "theme")
    FileUtils.mkdir_p(theme)
    File.write(File.join(theme, "hero.css"), %(a { color: red }\n))

    config = Propshaft::Config.new
    config.paths = [theme]
    config.version = "1"
    config.output_path = cmd_output_path
    config.manifest_path = cmd_manifest_path
    config.versions = [".gz"]
    assembly = Propshaft::Assembly.new(config)

    CRails::AssetsCommands.execute(assembly, "precompile")

    data = JSON.parse(File.read(cmd_manifest_path)).as_h
    data.keys.should contain("hero.css")
    digested = data["hero.css"].as_h["digested_path"].as_s
    File.exists?(File.join(cmd_output_path, digested)).should be_true
  end

  it "merges CRAILS_ASSETS_PATHS into the load path" do
    extra = File.join(CMD_ROOT, "vendor_extra")
    FileUtils.mkdir_p(extra)
    File.write(File.join(extra, "extra.js"), %(console.log(1)\n))

    config = Propshaft::Config.new
    config.version = "1"
    config.output_path = cmd_output_path
    config.manifest_path = cmd_manifest_path
    config.versions = [] of String
    assembly = Propshaft::Assembly.new(config)

    ENV["CRAILS_ASSETS_PATHS"] = extra
    begin
      CRails::AssetsCommands.execute(assembly, "precompile")
    ensure
      ENV.delete("CRAILS_ASSETS_PATHS")
    end

    data = JSON.parse(File.read(cmd_manifest_path)).as_h
    data.keys.should contain("extra.js")
  end

  it "clobbers the output path" do
    config = Propshaft::Config.new
    config.paths = [] of String
    config.output_path = cmd_output_path
    config.manifest_path = cmd_manifest_path
    assembly = Propshaft::Assembly.new(config)

    CRails::AssetsCommands.execute(assembly, "clobber")
    Dir.exists?(cmd_output_path).should be_false
  end
end

Spec.after_suite { FileUtils.rm_rf(CMD_ROOT) }
