# Generators oracle spec: 1:1 mirror of oracle/generators_expected.yml
# (Rails 8.1.4, captured by oracle/generators_cases.rb). The CRails port
# must reproduce the same file inventory, the same generated content
# semantics and the same stdout line format (invoke/create/identical/
# remove/route).
#
# Documented deviations from the Rails oracle (footer of this file):
# - .cr files; `ActiveRecord::Migration` without the [8.1] version tag
# - spec/ instead of test/ (specs + fixtures; no minitest/preview files)
# - `invoke spec` lines instead of `invoke test_unit`
# - routes carry an explicit `to:`; scaffold views build URLs by hand
# - `patch src/app.cr` lines are a CRails extension (no zeitwerk: the
#   requires for the touched app/ dirs are wired by the generator)

require "spec"
require "file_utils"
require "../src/railties_cr"
require "../src/generators/base"
require "../src/generators/fields"
require "../src/generators/migration_builder"
require "../src/generators/model_files"
require "../src/generators/app_glue"
require "../src/generators/migration_generator"
require "../src/generators/model_generator"
require "../src/generators/helper_generator"
require "../src/generators/job_generator"
require "../src/generators/mailer_generator"
require "../src/generators/channel_generator"
require "../src/generators/mailbox_generator"
require "../src/generators/controller_generator"
require "../src/generators/scaffold_generator"

# --- helpers -------------------------------------------------------------

def in_app(name : String, &) : Nil
  dir = File.join("tmp", "spec_apps", name)
  FileUtils.rm_rf(dir)
  FileUtils.mkdir_p(File.join(dir, "config"))
  FileUtils.mkdir_p(File.join(dir, "src"))
  File.write(File.join(dir, "src", "app.cr"), <<-CODE + "\n")
    require "railties_cr"

    require "../config/application"
    require "../app/controllers/**"
    require "../config/routes"
    CODE
  File.write(File.join(dir, "config", "application.cr"), <<-CODE + "\n")
    class Application < CRails::Application
    end
    CODE
  File.write(File.join(dir, "config", "routes.cr"), <<-CODE + "\n")
    CRails.application.routes.draw do
    end
    CODE
  old = Dir.current
  Dir.cd(dir)
  begin
    yield dir
  ensure
    Dir.cd(old)
  end

  FileUtils.rm_rf(dir)
end

# Run a generator in-process with captured stdout.
def run_gen(klass : CRails::Generators::Base.class, args : Array(String),
            behavior : Symbol = :invoke) : String
  io = IO::Memory.new
  gen = klass.new
  gen.behavior = behavior
  opts, rest = klass.parse_options(args)
  gen.force = opts.delete("force") || false
  gen.skip = opts.delete("skip") || false
  gen.pretend = opts.delete("pretend") || false
  gen.quiet = opts.delete("quiet") || false
  gen.skip_collision_check = opts.delete("skip-collision-check") || false
  gen.options = opts
  gen.args = rest
  gen.output = io
  gen.generate
  io.to_s
end

def norm(s : String) : String
  s.gsub(/\d{14}/, "TS")
end

def read(path : String) : String
  File.exists?(path) ? norm(File.read(path)) : "MISSING:#{path}"
end

# --- model ---------------------------------------------------------------

describe "generators: model (oracle model_basic)" do
  it "creates migration, model, spec and fixture" do
    in_app("model_basic") do
      stdout = run_gen(CRails::Generators::ModelGenerator,
        ["Post", "title:string", "body:text", "published:boolean"])
      expected = [
        "      invoke  active_record",
        "      create    db/migrate/TS_create_posts.cr",
        "      create    app/models/post.cr",
        "      invoke    spec",
        "      create      spec/models/post_spec.cr",
        "      create      spec/fixtures/posts.yml",
      ].join("\n") + "\n"
      (norm(stdout).lines.map(&.chomp).reject(&.includes?("patch")).join('\n') + "\n").should eq(expected)
      read("app/models/post.cr").should eq(<<-CODE + "\n")
        class Post < ApplicationRecord
        end
        CODE
      read("db/migrate/#{Dir.glob("db/migrate/*.cr").first.not_nil!.split('/').last}").should eq(<<-CODE + "\n")
        class CreatePosts < ActiveRecord::Migration
          def change
            create_table :posts do |t|
              t.string :title
              t.text :body
              t.boolean :published

              t.timestamps
            end
          end
        end
        CODE
      read("spec/fixtures/posts.yml").should eq(<<-YAML + "\n")
        # Read about fixtures at https://api.rubyonrails.org/classes/ActiveRecord/FixtureSet.html

        one:
          title: MyString
          body: MyText
          published: false
        two:
          title: MyString
          body: MyText
          published: false
        YAML
      read("src/app.cr").should contain("require \"../app/models/**\"")
    end
  end
end

describe "generators: model references (oracle model_reference)" do
  it "creates belongs_to, t.references with FK and fixture links" do
    in_app("model_ref") do
      run_gen(CRails::Generators::ModelGenerator,
        ["Comment", "body:text", "post:references"])
      read("app/models/comment.cr").should eq(<<-CODE + "\n")
        class Comment < ApplicationRecord
          belongs_to :post
        end
        CODE
      read(Dir.glob("db/migrate/*_create_comments.cr").first.not_nil!).should contain(
        "t.references :post, null: false, foreign_key: true")
      read("spec/fixtures/comments.yml").should contain("  post: one\n")
    end
  end
end

describe "generators: model polymorphic (oracle model_polymorphic)" do
  it "creates polymorphic belongs_to and reference" do
    in_app("model_poly") do
      run_gen(CRails::Generators::ModelGenerator,
        ["Tagging", "tag:references{polymorphic}"])
      read("app/models/tagging.cr").should eq(<<-CODE + "\n")
        class Tagging < ApplicationRecord
          belongs_to :tag, polymorphic: true
        end
        CODE
      read(Dir.glob("db/migrate/*_create_taggings.cr").first.not_nil!).should contain(
        "t.references :tag, polymorphic: true, null: false")
      read("spec/fixtures/taggings.yml").should contain("  tag_type: Tag\n")
    end
  end
end

describe "generators: model modifiers (oracle model_modifiers)" do
  it "applies limit/precision/scale and index/uniq" do
    in_app("model_mods") do
      run_gen(CRails::Generators::ModelGenerator,
        ["Product", "name:string{50}", "price:decimal{10,2}",
         "sku:string:uniq", "code:string:index"])
      read(Dir.glob("db/migrate/*_create_products.cr").first.not_nil!).should eq(<<-CODE + "\n")
        class CreateProducts < ActiveRecord::Migration
          def change
            create_table :products do |t|
              t.string :name, limit: 50
              t.decimal :price, precision: 10, scale: 2
              t.string :sku
              t.string :code

              t.timestamps
            end
            add_index :products, :code
            add_index :products, :sku, unique: true
          end
        end
        CODE
    end
  end
end

describe "generators: model namespace (oracle model_namespace)" do
  it "creates module with table_name_prefix" do
    in_app("model_ns") do
      run_gen(CRails::Generators::ModelGenerator, ["Admin::User", "email:string"])
      read("app/models/admin/user.cr").should eq("class Admin::User < ApplicationRecord\nend\n")
      read("app/models/admin.cr").should eq(<<-CODE + "\n")
        module Admin
          def self.table_name_prefix
            "admin_"
          end
        end
        CODE
      read(Dir.glob("db/migrate/*_create_admin_users.cr").first.not_nil!)
        .should contain("create_table :admin_users")
    end
  end
end

describe "generators: model flags (oracle model_no_* / pretend / twice)" do
  it "--no-migration skips the migration" do
    in_app("model_nomig") do
      run_gen(CRails::Generators::ModelGenerator,
        ["Post", "title:string", "--no-migration"])
      Dir.glob("db/migrate/*.cr").should be_empty
      File.exists?("app/models/post.cr").should be_true
    end
  end

  it "--no-timestamps omits t.timestamps" do
    in_app("model_nots") do
      run_gen(CRails::Generators::ModelGenerator,
        ["Post", "title:string", "--no-timestamps"])
      read(Dir.glob("db/migrate/*.cr").first.not_nil!).should_not contain("t.timestamps")
    end
  end

  it "--no-fixture skips the fixture" do
    in_app("model_nofix") do
      run_gen(CRails::Generators::ModelGenerator,
        ["Post", "title:string", "--no-fixture"])
      File.exists?("spec/fixtures/posts.yml").should be_false
      File.exists?("spec/models/post_spec.cr").should be_true
    end
  end

  it "--pretend logs but writes nothing" do
    in_app("model_pretend") do
      stdout = run_gen(CRails::Generators::ModelGenerator,
        ["Post", "title:string", "--pretend"])
      norm(stdout).should contain("create    db/migrate/TS_create_posts.cr")
      Dir.glob("app/models/*.cr").should be_empty
      Dir.glob("db/migrate/*.cr").should be_empty
    end
  end

  it "re-run stops on class collision (oracle model_twice)" do
    in_app("model_twice") do
      run_gen(CRails::Generators::ModelGenerator, ["Post", "title:string"])
      files = Dir.glob("db/migrate/*.cr")
      stdout = run_gen(CRails::Generators::ModelGenerator, ["Post", "title:string"])
      stdout.should eq("      invoke  active_record\n")
      Dir.glob("db/migrate/*.cr").size.should eq(1)
    end
  end

  it "re-run with --force reports identical files (oracle model_force)" do
    in_app("model_force") do
      run_gen(CRails::Generators::ModelGenerator, ["Post", "title:string"])
      stdout = run_gen(CRails::Generators::ModelGenerator,
        ["Post", "title:string", "--force"])
      norm(stdout).should contain("identical    db/migrate/TS_create_posts.cr")
      norm(stdout).should contain("identical    app/models/post.cr")
    end
  end
end

describe "generators: destroy model (oracle destroy_model)" do
  it "removes exactly what it created" do
    in_app("destroy_model") do
      run_gen(CRails::Generators::ModelGenerator, ["Post", "title:string"])
      stdout = run_gen(CRails::Generators::ModelGenerator,
        ["Post", "title:string"], :revoke)
      expected = [
        "      invoke  active_record",
        "      remove    db/migrate/TS_create_posts.cr",
        "      remove    app/models/post.cr",
        "      invoke    spec",
        "      remove      spec/models/post_spec.cr",
        "      remove      spec/fixtures/posts.yml",
      ].join("\n") + "\n"
      (norm(stdout).lines.map(&.chomp).reject(&.includes?("patch")).join('\n') + "\n").should eq(expected)
      File.exists?("app/models/post.cr").should be_false
      Dir.glob("db/migrate/*.cr").should be_empty
      File.exists?("spec/fixtures/posts.yml").should be_false
    end
  end
end

# --- migration -----------------------------------------------------------

describe "generators: migration (oracle mig_* cases)" do
  it "AddXxxToYyy with index (mig_add)" do
    in_app("mig_add") do
      run_gen(CRails::Generators::MigrationGenerator,
        ["AddTitleToPosts", "title:string:index"])
      read(Dir.glob("db/migrate/*_add_title_to_posts.cr").first.not_nil!).should eq(<<-CODE + "\n")
        class AddTitleToPosts < ActiveRecord::Migration
          def change
            add_column :posts, :title, :string
            add_index :posts, :title
          end
        end
        CODE
    end
  end

  it "AddUserToPosts with references (mig_add_ref)" do
    in_app("mig_add_ref") do
      run_gen(CRails::Generators::MigrationGenerator,
        ["AddUserToPosts", "user:references"])
      read(Dir.glob("db/migrate/*_add_user_to_posts.cr").first.not_nil!)
        .should contain("add_reference :posts, :user, null: false, foreign_key: true")
    end
  end

  it "AddTagToProducts polymorphic (mig_add_poly)" do
    in_app("mig_add_poly") do
      run_gen(CRails::Generators::MigrationGenerator,
        ["AddTagToProducts", "tag:references{polymorphic}"])
      read(Dir.glob("db/migrate/*_add_tag_to_products.cr").first.not_nil!)
        .should contain("add_reference :products, :tag, polymorphic: true, null: false")
    end
  end

  it "RemoveXxxFromYyy keeps the type (mig_remove)" do
    in_app("mig_remove") do
      run_gen(CRails::Generators::MigrationGenerator,
        ["RemoveTitleFromPosts", "title:string"])
      read(Dir.glob("db/migrate/*_remove_title_from_posts.cr").first.not_nil!).should eq(<<-CODE + "\n")
        class RemoveTitleFromPosts < ActiveRecord::Migration
          def change
            remove_column :posts, :title, :string
          end
        end
        CODE
    end
  end

  it "unknown names leave change empty (mig_rename/mig_join/mig_plain)" do
    ["RenameTitleToSubjectOnPosts", "CreateJoinTableCoreMembersRooms",
     "AddIndexToPostsOnTitle"].each do |name|
      in_app("mig_plain_#{name.hash}") do
        run_gen(CRails::Generators::MigrationGenerator, [name])
        content = read(Dir.glob("db/migrate/*.cr").first.not_nil!)
        content.should contain("class #{name} < ActiveRecord::Migration")
        content.should contain("  def change\n  end")
      end
    end
  end
end

# --- controller ----------------------------------------------------------

describe "generators: controller (oracle controller_*)" do
  it "with actions creates controller, routes, views, spec, helper" do
    in_app("ctrl_actions") do
      stdout = run_gen(CRails::Generators::ControllerGenerator,
        ["Comments", "show", "create"])
      expected = [
        "      create  app/controllers/comments_controller.cr",
        %(       route  get "comments/show", to: "comments#show"),
        %(              get "comments/create", to: "comments#create"),
      ].join("\n")
      norm(stdout).lines.map(&.chomp).reject(&.includes?("patch")).join('\n').should contain(expected)
      read("app/controllers/comments_controller.cr").should eq(<<-CODE + "\n")
        class CommentsController < ApplicationController
          def show
          end

          def create
          end
        end
        CODE
      read("app/views/comments/show.html.erb").should eq(<<-ERB + "\n")
        <h1>Comments#show</h1>
        <p>Find me in app/views/comments/show.html.erb</p>
        ERB
      read("config/routes.cr").should contain(%(get "comments/show", to: "comments#show"))
    end
  end

  it "without actions skips routes and views (controller_basic)" do
    in_app("ctrl_basic") do
      stdout = run_gen(CRails::Generators::ControllerGenerator, ["Posts"])
      stdout.should contain("create  app/controllers/posts_controller.cr")
      stdout.should_not contain("route")
      Dir.glob("app/views/posts/*").should be_empty
    end
  end

  it "destroy removes files and the route lines" do
    in_app("ctrl_destroy") do
      run_gen(CRails::Generators::ControllerGenerator, ["Posts", "index", "show"])
      stdout = run_gen(CRails::Generators::ControllerGenerator,
        ["Posts", "index", "show"], :revoke)
      stdout.should contain("remove  app/controllers/posts_controller.cr")
      File.exists?("app/controllers/posts_controller.cr").should be_false
      read("config/routes.cr").should_not contain("posts/index")
      File.exists?("app/helpers/posts_helper.cr").should be_false
    end
  end
end

# --- scaffold ------------------------------------------------------------

describe "generators: scaffold (oracle scaffold_post)" do
  it "composes model + route + controller + views + helper" do
    in_app("scaffold_post") do
      stdout = run_gen(CRails::Generators::ScaffoldGenerator,
        ["Post", "title:string", "body:text", "published:boolean"])
      expected = [
        "      invoke  active_record",
        "      create    db/migrate/TS_create_posts.cr",
        "      create    app/models/post.cr",
        "      invoke    spec",
        "      create      spec/models/post_spec.cr",
        "      create      spec/fixtures/posts.yml",
        "      invoke  resource_route",
        "       route    resources :posts",
        "      invoke  scaffold_controller",
        "      create    app/controllers/posts_controller.cr",
      ].join("\n")
      norm(stdout).lines.map(&.chomp).reject(&.includes?("patch")).join('\n').should contain(expected)
      %w[index edit show new _form _post].each do |view|
        File.exists?("app/views/posts/#{view}.html.erb").should be_true
      end
      read("config/routes.cr").should contain("resources :posts")
      ctrl = read("app/controllers/posts_controller.cr")
      ctrl.should contain("before_action :set_post, only: [:show, :edit, :update, :destroy]")
      ctrl.should contain(%(redirect_to("/posts/\#{post.id}", notice: "Post was successfully created.")))
      ctrl.should contain(%("published" => pp["published"]? == "1" || pp["published"]? == "true"))
    end
  end

  it "destroy removes everything including routes" do
    in_app("scaffold_destroy") do
      run_gen(CRails::Generators::ScaffoldGenerator, ["Post", "title:string"])
      run_gen(CRails::Generators::ScaffoldGenerator,
        ["Post", "title:string"], :revoke)
      File.exists?("app/controllers/posts_controller.cr").should be_false
      File.exists?("app/models/post.cr").should be_false
      Dir.glob("db/migrate/*_create_posts.cr").should be_empty
      read("config/routes.cr").should_not contain("resources :posts")
    end
  end
end

# --- mailer / job / channel / mailbox / helper ---------------------------

describe "generators: mailer (oracle mailer_basic)" do
  it "creates mailer, text+html views per action and spec" do
    in_app("mailer") do
      stdout = run_gen(CRails::Generators::MailerGenerator,
        ["UserMailer", "welcome", "farewell"])
      expected = [
        "      create  app/mailers/user_mailer.cr",
        "      invoke  erb",
        "      create    app/views/user_mailer",
        "      create    app/views/user_mailer/welcome.text.erb",
        "      create    app/views/user_mailer/welcome.html.erb",
      ].join("\n")
      norm(stdout).lines.map(&.chomp).reject(&.includes?("patch")).join('\n').should contain(expected)
      mailer = read("app/mailers/user_mailer.cr")
      mailer.should contain("class UserMailer < ApplicationMailer")
      mailer.should contain("mail(to: \"to@example.com\")")
      read("app/views/user_mailer/welcome.text.erb").should eq(<<-ERB + "\n")
        User#welcome

        <%= @greeting %>, find me in app/views/user_mailer/welcome.text.erb
        ERB
    end
  end
end

describe "generators: job (oracle job_basic)" do
  it "creates the job with queue_as" do
    in_app("job") do
      run_gen(CRails::Generators::JobGenerator, ["Cleanup"])
      read("app/jobs/cleanup_job.cr").should eq(<<-CODE + "\n")
        class CleanupJob < ApplicationJob
          queue_as :default

          def perform(*args)
            # Do something later
          end
        end
        CODE
      File.exists?("spec/jobs/cleanup_job_spec.cr").should be_true
    end
  end
end

describe "generators: channel (oracle channel_basic)" do
  it "bootstraps application_cable and the channel" do
    in_app("channel") do
      run_gen(CRails::Generators::ChannelGenerator, ["Room"])
      read("app/channels/application_cable/channel.cr").should eq(<<-CODE + "\n")
        module ApplicationCable
          class Channel < ActionCable::Channel::Base
          end
        end
        CODE
      read("app/channels/room_channel.cr").should contain("class RoomChannel < ApplicationCable::Channel")
    end
  end
end

describe "generators: mailbox (oracle mailbox_basic)" do
  it "creates mailbox and application_mailbox" do
    in_app("mailbox") do
      run_gen(CRails::Generators::MailboxGenerator, ["Reactions"])
      read("app/mailboxes/reactions_mailbox.cr").should eq(<<-CODE + "\n")
        class ReactionsMailbox < ApplicationMailbox
          def process
          end
        end
        CODE
      File.exists?("app/mailboxes/application_mailbox.cr").should be_true
    end
  end
end

describe "generators: helper (oracle helper_basic)" do
  it "creates the helper module" do
    in_app("helper") do
      run_gen(CRails::Generators::HelperGenerator, ["post"])
      read("app/helpers/post_helper.cr").should eq("module PostHelper\nend\n")
    end
  end
end

# Deviations from the Rails 8.1.4 oracle (oracle/generators_expected.yml):
# - .cr sources; `ActiveRecord::Migration` (no [8.1] tag — CRails has no
#   versioned migration base)
# - spec/ files instead of minitest test/ (specs + fixtures; Rails'
#   previews for mailers are not ported)
# - `invoke spec` instead of `invoke test_unit`
# - controller routes need `to:`; scaffold URLs are literal paths (no
#   named route url helpers yet); scaffold form is a raw <form> (no
#   FormModel across shards)
# - `patch src/app.cr` status lines are a CRails extension (wiring the
#   requires for touched app/ dirs — no zeitwerk in Crystal)
# - channel generator skips the JS/importmap files (no asset pipeline)
# - connection template subclasses ActionCable::Connection (the port has
#   no Connection::Base); channels also get an explicit
#   application_cable require (glob order)
# - migration versions are monotonic within a second (migrator orders
#   strictly by version); mailbox apps get an active_storage install
#   migration (model codegen reads the app's db/schema.yml)
