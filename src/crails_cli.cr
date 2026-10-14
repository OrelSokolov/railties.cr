require "./railties_cr"
require "./cli"

# Bake the completion table for the console's line editor (Tab / ^T):
# harvests the stdlib + everything this CLI program sees. The user's
# app types live in the prelude process, not here — those are not in
# the table, stdlib completion still applies to typed lines.
Icr.enable_autocomplete!

CRails::CLI.run(ARGV)
