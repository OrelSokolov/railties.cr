# Точка входа для интеграционного спека супервизора (spec/supervise_spec.cr):
# crystal src/supervisor_entry.cr PROCFILE [ROLE]
require "./railties_cr"
require "./supervisor"

CRails::CLI::Supervisor.run(ARGV)
