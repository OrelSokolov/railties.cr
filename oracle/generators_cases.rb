# Oracle cases for generators (Iteration: `crails generate/destroy`): run
# the ORIGINAL Rails 8.1.4 generators in a scratch app and capture stdout +
# created/changed files, normalized (migration timestamps -> TS).
#
# Setup once:
#   rails _8.1.4_ new /tmp/rails8_gen_pristine \
#     --skip-git --skip-test --skip-system-test --skip-bootsnap \
#     --skip-jbuilder --skip-docker --skip-ci
# Then, from railties.cr/:
#   ruby oracle/generators_cases.rb > oracle/generators_expected.yml
#
# Mirrored in spec/generators_spec.cr: the CRails port must reproduce the
# same file inventory, the same generated-content semantics and the same
# stdout line format (invoke/create/identical/force/remove), modulo the
# documented deviations (Crystal files, specs instead of minitest).

require "open3"
require "yaml"
require "digest"
require "fileutils"

PRISTINE = ENV.fetch("PRISTINE", "/tmp/rails8_gen_pristine")
WORK     = ENV.fetch("WORK", "/tmp/rails8_gen")

# Files that legitimately change while running any rails command.
SKIP = %r{\A(\.git|log|tmp|tmp/|storage|db/.*\.sqlite3|coverage|node_modules)}

def reset_work
  FileUtils.remove_entry(WORK) if File.exist?(WORK)
  system("cp -a #{PRISTINE} #{WORK}") or abort "cannot clone #{PRISTINE}"
end

def inventory(dir)
  files = Dir.glob("#{dir}/**/*", File::FNM_DOTMATCH)
             .select { |f| File.file?(f) }
             .map { |f| f.delete_prefix("#{dir}/") }
             .reject { |f| f =~ SKIP }
  files.to_h { |f| [f, Digest::SHA256.file(File.join(dir, f)).hexdigest] }
end

def normalize(s)
  s.gsub(/\d{14}/, "TS")
end

CASES = {
  # --- help texts (usage format 1:1) -----------------------------------
  "help_generate"  => ["generate"],
  "help_model"     => ["generate", "model", "--help"],
  "help_migration" => ["generate", "migration", "--help"],
  "help_scaffold"  => ["generate", "scaffold", "--help"],

  # --- model -------------------------------------------------------------
  "model_basic"       => [["g", "model", "Post", "title:string", "body:text", "published:boolean"]],
  "model_reference"   => [["g", "model", "Comment", "body:text", "post:references"]],
  "model_polymorphic" => [["g", "model", "Tagging", "tag:references{polymorphic}"]],
  "model_modifiers"   => [["g", "model", "Product", "name:string{50}", "price:decimal{10,2}",
                                    "sku:string:uniq", "code:string:index"]],
  "model_types"       => [["g", "model", "Event", "starts_at:datetime", "ratio:decimal",
                                    "score:float", "held_on:date", "opens_at:time"]],
  "model_namespace"   => [["g", "model", "Admin::User", "email:string"]],
  "model_no_migration"=> [["g", "model", "Post", "title:string", "--no-migration"]],
  "model_no_timestamps" => [["g", "model", "Post", "title:string", "--no-timestamps"]],
  "model_no_indexes"  => [["g", "model", "Comment", "body:text", "post:references", "--no-indexes"]],
  "model_no_fixture"  => [["g", "model", "Post", "title:string", "--no-fixture"]],
  "model_pretend"     => [["g", "model", "Post", "title:string", "--pretend"]],
  "model_twice"       => [["g", "model", "Post", "title:string"],
                          ["g", "model", "Post", "title:string"]],
  "model_force"       => [["g", "model", "Post", "title:string"],
                          ["g", "model", "Post", "title:string", "--force"]],
  "destroy_model"     => [["g", "model", "Post", "title:string"],
                          ["destroy", "model", "Post", "title:string"]],

  # --- migration ---------------------------------------------------------
  "mig_create"      => [["g", "migration", "CreateProducts", "name:string"]],
  "mig_add"         => [["g", "migration", "AddTitleToPosts", "title:string:index"]],
  "mig_add_many"    => [["g", "migration", "AddDetailsToPosts", "title:string", "views:integer"]],
  "mig_add_ref"     => [["g", "migration", "AddUserToPosts", "user:references"]],
  "mig_add_poly"    => [["g", "migration", "AddTagToProducts", "tag:references{polymorphic}"]],
  "mig_remove"      => [["g", "migration", "RemoveTitleFromPosts", "title:string"]],
  "mig_remove_many" => [["g", "migration", "RemoveFieldsFromPosts", "title:string", "body:text"]],
  "mig_rename"      => [["g", "migration", "RenameTitleToSubjectOnPosts"]],
  "mig_join"        => [["g", "migration", "CreateJoinTableCoreMembersRooms"]],
  "mig_plain"       => [["g", "migration", "AddIndexToPostsOnTitle"]],
  "mig_polymorphic_model" => [["g", "model", "Picture", "imageable:references{polymorphic}"]],

  # --- controller ----------------------------------------------------------
  "controller_basic"   => [["g", "controller", "Posts"]],
  "controller_actions" => [["g", "controller", "Comments", "show", "create"]],
  "controller_skip"    => [["g", "controller", "Posts", "index"],
                           ["g", "controller", "Posts", "index", "--skip"]],
  "destroy_controller" => [["g", "controller", "Posts", "index", "show"],
                           ["destroy", "controller", "Posts", "index", "show"]],

  # --- scaffold ------------------------------------------------------------
  "scaffold_post"   => [["g", "scaffold", "Post", "title:string", "body:text", "published:boolean"]],
  "destroy_scaffold"=> [["g", "scaffold", "Post", "title:string"],
                        ["destroy", "scaffold", "Post", "title:string"]],

  # --- mailer / job / channel / mailbox / helper ---------------------------
  "mailer_basic"    => [["g", "mailer", "UserMailer", "welcome", "farewell"]],
  "destroy_mailer"  => [["g", "mailer", "UserMailer", "welcome"],
                        ["destroy", "mailer", "UserMailer", "welcome"]],
  "job_basic"       => [["g", "job", "Cleanup"]],
  "channel_basic"   => [["g", "channel", "Room"]],
  "mailbox_basic"   => [["g", "mailbox", "Reactions"]],
  "helper_basic"    => [["g", "helper", "post"]],
}

results = {}

CASES.each do |id, cmds|
  cmds = [cmds] if cmds.first.is_a?(String)
  reset_work
  before = inventory(WORK)
  steps = cmds.map do |argv|
    display = (["rails"] + argv).join(" ")
    out, err, st = Open3.capture3("bin/rails", *argv.map(&:to_s), chdir: WORK)
    { "argv" => display, "stdout" => normalize(out), "stderr" => err,
      "status" => st.exitstatus }
  end
  after = inventory(WORK)
  created = (after.keys - before.keys).sort
  changed = after.select { |f, h| before[f] && before[f] != h }.keys.sort
  files = {}
  (created + changed).sort.each do |f|
    files[f] = { "state" => created.include?(f) ? "created" : "changed",
                 "content" => normalize(File.read(File.join(WORK, f))) }
  end
  results[id] = { "steps" => steps, "files" => files }
  warn "case #{id}: #{created.size} created, #{changed.size} changed"
end

puts YAML.dump(results)
