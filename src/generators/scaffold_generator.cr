# `crails generate scaffold NAME [fields]` — 1:1 with Rails ScaffoldGenerator
# (oracle: scaffold_post): model + resource_route + scaffold_controller
# (controller, 6 views, spec, helper).
#
# Deviations (documented in PLAN.md): routes need an explicit `to:`/the
# `resources` macro; views build URLs by hand (no named route helpers yet)
# and the form is a raw `<form>` (no FormModel implementation across
# shards); strong params go through a typed `#{name}_values` helper;
# partials render through per-controller compile_partials (CRails compiles
# templates at compile time).

module CRails
  module Generators
    class ScaffoldGenerator < NamedBase
      include ModelFiles

      @fields = [] of Field

      def generate : Nil
        super
        @fields = parse_fields

        invoke("active_record") do
          return if check_class_collision(File.join("app", "models", "#{file_path}.cr"),
                      full_class_name)
          create_model_files(self, @fields)
        end

        invoke("resource_route") do
          route(["resources :#{table_name}"])
        end

        invoke("scaffold_controller") do
          create_scaffold_controller
          invoke("erb") { create_scaffold_views }
          invoke("resource_route")
          invoke("spec") do
            create_file(File.join("spec", "controllers", "#{controller_path}_controller_spec.cr"),
              <<-CODE + "\n")
              require "spec_helper"

              describe #{controller_class_name}Controller do
                # test "should get index" do
                #   get "/#{table_name}"
                #   assert_response :success
                # end
              end
              CODE
          end
          invoke("helper") do
            create_file(File.join("app", "helpers", "#{controller_path}_helper.cr"),
              <<-CODE + "\n")
              module #{controller_class_name}Helper
              end
              CODE
            invoke("spec")
          end
        end

        AppGlue.patch_requires(self, "app/models")
        AppGlue.patch_requires(self, "app/controllers")
        AppGlue.patch_requires(self, "app/helpers")
      end

      def parse_fields : Array(Field)
        Fields.parse_all(raw_attributes)
      rescue e : Fields::UnknownFieldType
        name, type = e.field.split(':', 2)
        STDERR.puts "Could not generate field '#{name}' with unknown type '#{type}'."
        exit 0
      end

      def usage : String
        "Usage: crails generate scaffold NAME [field:type ...]"
      end

      # Controller/routes use the plural form (scaffold Post ->
      # PostsController + app/views/posts/), like Rails.
      def controller_path : String
        (class_path + [singular_name.pluralize]).join("/")
      end

      def controller_class_name : String
        controller_path.camelize
      end

      private def create_scaffold_controller : Nil
        body = String.build do |io|
          io << "class #{controller_class_name}Controller < ApplicationController\n"
          io << "  compile_partials({\n"
          io << "    \"#{controller_path}/form\" => {path: \"app/views/#{controller_path}/_form.html.erb\", locals: {\"#{singular_name}\" => #{full_class_name}}},\n"
          io << "    \"#{controller_path}/#{singular_name}\" => {path: \"app/views/#{controller_path}/_#{singular_name}.html.erb\", locals: {\"#{singular_name}\" => #{full_class_name}}},\n"
          io << "  })\n\n"
          io << scaffold_controller_body
        end
        create_file(File.join("app", "controllers", "#{controller_path}_controller.cr"), body)
      end

      private def scaffold_controller_body : String
        String.build do |io|
          io << "  @#{table_name} : Array(#{full_class_name}) = [] of #{full_class_name}\n"
          io << "  @#{singular_name} : #{full_class_name}? = nil\n\n"
          io << "  before_action :set_#{singular_name}, only: [:show, :edit, :update, :destroy]\n\n"

          io << "  # GET /#{table_name}\n"
          io << "  def index\n"
          io << "    @#{table_name} = #{full_class_name}.all.to_a\n"
          io << "  end\n\n"

          io << "  # GET /#{table_name}/:id\n"
          io << "  def show\n"
          io << "  end\n\n"

          io << "  # GET /#{table_name}/new\n"
          io << "  def new\n"
          io << "    @#{singular_name} = #{full_class_name}.new\n"
          io << "  end\n\n"

          io << "  # GET /#{table_name}/:id/edit\n"
          io << "  def edit\n"
          io << "  end\n\n"

          io << "  # POST /#{table_name}\n"
          io << "  def create\n"
          io << "    #{singular_name} = #{full_class_name}.new\n"
          io << "    #{singular_name}.assign_attributes(#{singular_name}_values(params.require(\"#{singular_name}\")))\n"
          io << "    if #{singular_name}.save\n"
          io << "      redirect_to(\"/#{table_name}/\#{#{singular_name}.id}\", notice: \"#{human_name} was successfully created.\")\n"
          io << "    else\n"
          io << "      @#{singular_name} = #{singular_name}\n"
          io << "      render_action(\"new\", 422)\n"
          io << "    end\n"
          io << "  end\n\n"

          io << "  # PATCH/PUT /#{table_name}/:id\n"
          io << "  def update\n"
          io << "    #{singular_name} = @#{singular_name}.not_nil!\n"
          io << "    if #{singular_name}.update(#{singular_name}_values(params.require(\"#{singular_name}\")))\n"
          io << "      redirect_to(\"/#{table_name}/\#{#{singular_name}.id}\", notice: \"#{human_name} was successfully updated.\")\n"
          io << "    else\n"
          io << "      @#{singular_name} = #{singular_name}\n"
          io << "      render_action(\"edit\", 422)\n"
          io << "    end\n"
          io << "  end\n\n"

          io << "  # DELETE /#{table_name}/:id\n"
          io << "  def destroy\n"
          io << "    @#{singular_name}.not_nil!.destroy\n"
          io << "    redirect_to(\"/#{table_name}\", notice: \"#{human_name} was successfully destroyed.\")\n"
          io << "  end\n\n"

          io << "  # render :new/:edit with a non-200 status (action_pack's\n"
          io << "  # implicit render only knows the current action).\n"
          io << "  def render_action(action : String, status : Int32) : Nil\n"
          io << "    response.status_code = status\n"
          io << "    __default_render(action)\n"
          io << "  end\n\n"

          io << "  private def set_#{singular_name} : Nil\n"
          io << "    @#{singular_name} = #{full_class_name}.find(params[\"id\"].to_s.to_i64)\n"
          io << "  end\n\n"

          io << "  private def #{singular_name}_values(pp : ActionController::Parameters)\n"
          io << "    {\n"
          plain_fields.each do |f|
            io << "      \"#{value_key(f)}\" => #{param_expr(f)},\n"
          end
          io << "    } of String => ActiveRecord::Value\n"
          io << "  end\n"
          io << "end\n"
        end
      end

      # Non-reference fields (references surface as plain `name_id` ints).
      private def plain_fields : Array(Field)
        @fields
      end

      private def param_expr(f : Field) : String
        key = value_key(f)
        case f.type
        when "integer", "references", "belongs_to" then %(pp["#{key}"]?.try(&.to_s.to_i64))
        when "float", "decimal"                    then %(pp["#{key}"]?.try(&.to_s.to_f64))
        when "boolean"                             then %(pp["#{key}"]? == "1" || pp["#{key}"]? == "true")
        when "datetime", "timestamp"
          %(pp["#{key}"]?.try { |v| Time.parse?(v.to_s, "%Y-%m-%d %H:%M:%S") || Time.parse?(v.to_s, "%Y-%m-%dT%H:%M:%S") })
        when "time" then %(pp["#{key}"]?.try { |v| Time.parse?(v.to_s, "%H:%M:%S") })
        when "date" then %(pp["#{key}"]?.try { |v| Time.parse?(v.to_s, "%Y-%m-%d") })
        else             %(pp["#{key}"]?.to_s)
        end
      end

      # References surface as plain `name_id` integer params.
      private def value_key(f : Field) : String
        f.reference? ? "#{f.name}_id" : f.name
      end

      private def human_name : String
        singular_name.split('_').map(&.capitalize).join(' ')
      end

      private def create_scaffold_views : Nil
        dir = File.join("app", "views", controller_path)
        create_dir(dir)

        create_file(File.join(dir, "index.html.erb"), <<-ERB + "\n")
          <p style="color: green"><%= flash["notice"] %></p>

          <h1>#{human_name.pluralize}</h1>

          <div id="#{table_name}">
            <% #{table_name} = @#{table_name} %>
            <% #{table_name}.each do |#{singular_name}| %>
              <%= render partial: "#{controller_path}/#{singular_name}", locals: {"#{singular_name}" => #{singular_name}} %>
              <p>
                <%= link_to "Show this #{human_name.downcase}", "/#{table_name}/\#{#{singular_name}.id}" %>
              </p>
            <% end %>
          </div>

          <%= link_to "New #{human_name.downcase}", "/#{table_name}/new" %>
          ERB

        create_file(File.join(dir, "edit.html.erb"), <<-ERB + "\n")
          <h1>Editing #{human_name.downcase}</h1>

          <% #{singular_name} = @#{singular_name}.not_nil! %>
          <%= render partial: "#{controller_path}/form", locals: {"#{singular_name}" => #{singular_name}} %>

          <br>

          <div>
            <%= link_to "Show this #{human_name.downcase}", "/#{table_name}/\#{#{singular_name}.id}" %> |
            <%= link_to "Back to #{human_name.pluralize.downcase}", "/#{table_name}" %>
          </div>
          ERB

        create_file(File.join(dir, "show.html.erb"), <<-ERB + "\n")
          <p style="color: green"><%= flash["notice"] %></p>

          <% #{singular_name} = @#{singular_name}.not_nil! %>
          <%= render partial: "#{controller_path}/#{singular_name}", locals: {"#{singular_name}" => #{singular_name}} %>

          <div>
            <%= link_to "Edit this #{human_name.downcase}", "/#{table_name}/\#{#{singular_name}.id}/edit" %> |
            <%= link_to "Back to #{human_name.pluralize.downcase}", "/#{table_name}" %>

            <%= button_to "Destroy this #{human_name.downcase}", "/#{table_name}/\#{#{singular_name}.id}", method: :delete %>
          </div>
          ERB

        create_file(File.join(dir, "new.html.erb"), <<-ERB + "\n")
          <h1>New #{human_name.downcase}</h1>

          <% #{singular_name} = @#{singular_name}.not_nil! %>
          <%= render partial: "#{controller_path}/form", locals: {"#{singular_name}" => #{singular_name}} %>

          <br>

          <div>
            <%= link_to "Back to #{human_name.pluralize.downcase}", "/#{table_name}" %>
          </div>
          ERB

        create_file(File.join(dir, "_form.html.erb"), form_template)
        create_file(File.join(dir, "_#{singular_name}.html.erb"), record_template)
      end

      private def form_template : String
        String.build do |io|
          io << "<% unless #{singular_name}.errors.empty? %>\n"
          io << "  <div style=\"color: red\">\n"
          io << "    <h2><%= pluralize(#{singular_name}.errors.size, \"error\") %> prohibited this #{singular_name} from being saved:</h2>\n\n"
          io << "    <ul>\n"
          io << "      <% #{singular_name}.errors.full_messages.each do |message| %>\n"
          io << "        <li><%= message %></li>\n"
          io << "      <% end %>\n"
          io << "    </ul>\n"
          io << "  </div>\n"
          io << "<% end %>\n\n"
          io << "<% url = #{singular_name}.persisted? ? \"/#{table_name}/\#{#{singular_name}.id}\" : \"/#{table_name}\" %>\n"
          io << "<% method = #{singular_name}.persisted? ? \"patch\" : \"post\" %>\n"
          io << "<form action=\"<%= url %>\" accept-charset=\"UTF-8\" method=\"post\">\n"
          io << "  <input type=\"hidden\" name=\"_method\" value=\"<%= method %>\" />\n"
          plain_fields.each do |f|
            name = f.reference? ? "#{f.name}_id" : f.name
            label = f.reference? ? f.name : f.name
            io << "\n  <div>\n"
            io << "    <label for=\"#{singular_name}_#{name}\">#{humanize_word(name)}</label>\n"
            case f.type
            when "text"
              io << "    <textarea name=\"#{singular_name}[#{name}]\" id=\"#{singular_name}_#{name}\"><%= #{singular_name}.#{name} %></textarea>\n"
            when "boolean"
              io << "    <input type=\"hidden\" name=\"#{singular_name}[#{name}]\" value=\"0\" />\n"
              io << "    <input type=\"checkbox\" name=\"#{singular_name}[#{name}]\" id=\"#{singular_name}_#{name}\" value=\"1\" <%= #{singular_name}.#{name} ? \"checked\" : \"\" %> />\n"
            when "integer", "float", "decimal"
              io << "    <input type=\"number\" step=\"any\" name=\"#{singular_name}[#{name}]\" id=\"#{singular_name}_#{name}\" value=\"<%= #{singular_name}.#{name} %>\" />\n"
            when "date", "datetime", "timestamp", "time"
              io << "    <input type=\"text\" name=\"#{singular_name}[#{name}]\" id=\"#{singular_name}_#{name}\" value=\"<%= #{singular_name}.#{name} %>\" />\n"
            else
              io << "    <input type=\"text\" name=\"#{singular_name}[#{name}]\" id=\"#{singular_name}_#{name}\" value=\"<%= #{singular_name}.#{name} %>\" />\n"
            end
            io << "  </div>\n"
          end
          io << "\n  <div>\n    <input type=\"submit\" value=\"Save\" />\n  </div>\n"
          io << "</form>\n"
        end
      end

      private def record_template : String
        String.build do |io|
          io << "<div id=\"<%= dom_id #{singular_name} %>\">\n"
          plain_fields.each do |f|
            attr = value_key(f)
            io << "  <div>\n"
            io << "    <strong>#{humanize_word(attr)}:</strong>\n"
            io << "    <%= #{singular_name}.#{attr} %>\n"
            io << "  </div>\n\n"
          end
          io << "</div>\n"
        end
      end

      private def humanize_word(word : String) : String
        word.split('_').map(&.capitalize).join(' ')
      end
    end
  end
end
