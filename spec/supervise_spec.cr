# Process roles spec: CRails::CLI::Supervisor (Procfile parsing,
# crash-restart with backoff, exit-3 role disabling, TERM shutdown).

require "spec"
require "../src/railties_cr"
require "../src/supervisor"
require "file_utils"

describe "process roles" do
  it "parse_procfile reads foreman roles" do
    dir = File.join(Dir.tempdir, "crails_sup_spec_#{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(dir)
    procfile = File.join(dir, "Procfile")
    File.write(procfile, <<-TEXT)
    # comment
    web: bin/app serve -p 3000
    worker: bin/app worker
    TEXT
    roles = CRails::CLI::Supervisor.parse_procfile(procfile)
    roles.map(&.name).should eq(["web", "worker"])
    roles[0].command.should eq("bin/app serve -p 3000")
    roles[1].command.should eq("bin/app worker")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "restarts a crashed role and disables exit-3 roles (integration)" do
    # Прекомпилируем supervisor: Process.new("crystal", ...) гонял бы
    # компиляцию при каждом спеке (и терялся бы TERM, пришедший до
    # установки trap).
    bin = File.join(__DIR__, "..", "tmp", "supervisor_entry_spec")
    FileUtils.mkdir_p(File.dirname(bin))
    system("crystal build src/supervisor_entry.cr -o #{bin}") ||
      abort "cannot build supervisor entry"

    dir = File.join(Dir.tempdir, "crails_sup_run_#{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(dir)
    ticks = File.join(dir, "ticks")
    procfile = File.join(dir, "Procfile")
    # ticker: appends a line and exits (supervisor must restart it);
    # broken: exits with code 3 immediately (must be disabled after 1 run)
    File.write(procfile, <<-TEXT)
    ticker: echo tick >> #{ticks}
    broken: echo broken >> #{dir}/broken; exit 3
    TEXT

    supervisor = Process.new(bin, [procfile],
      output: Process::Redirect::Inherit,
      error: Process::Redirect::Inherit)

    # ждём готовности (первый тик) — потом даём ~2 рестарт-цикла (1-2s backoff)
    ready = false
    100.times do
      if File.exists?(ticks)
        ready = true
        break
      end
      sleep 100.milliseconds
    end
    ready.should be_true
    sleep 3.seconds
    supervisor.terminate
    supervisor.wait

    ticks_count = File.exists?(ticks) ? File.read(ticks).lines.size : 0
    ticks_count.should be >= 2 # restarted at least once
    broken = File.join(dir, "broken")
    broken_count = File.exists?(broken) ? File.read(broken).lines.size : 0
    broken_count.should eq(1) # disabled after the first exit-3
  ensure
    (supervisor.try(&.terminate) rescue nil)
    (supervisor.try(&.wait) rescue nil)
    FileUtils.rm_rf(dir) if dir
  end
end
