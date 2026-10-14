# Mirror of action_pack.cr/oracle/data_streaming_expected.yml (captured
# from actionpack 8.1.4 via action_pack.cr/oracle/data_streaming_cases.rb).
# Same case IDs, same expectations. Runs the full CRails stack; the value
# format mirrors the oracle: "status|CT|CD|CTE|CL|body".
#
# CL (Content-Length) is empty in the oracle (Rack streams); on the
# wire CRails' HTTP::Server adds it — the mirror pins "" and documents
# the deviation.

require "spec"
require "../src/railties_cr"
require "file_utils"

DS_EXPECTED = begin
  hash = {} of String => String
  File.read("#{__DIR__}/../../action_pack.cr/oracle/data_streaming_expected.yml").each_line do |line|
    next unless line.includes?('\t')
    id, value = line.split('\t', 2)
    hash[id] = value.chomp.gsub("\\n", "\n")
  end
  hash
end

DIR = File.join(Dir.tempdir, "crails_ds_spec_#{Random::Secure.hex(4)}")
FileUtils.mkdir_p(DIR)
File.write(File.join(DIR, "notes.txt"), "file body\n")
File.write(File.join(DIR, "report.pdf"), "%PDF-fake")
File.write(File.join(DIR, "data.bin"), "\x00\x01binary")
File.write(File.join(DIR, "страница.html"), "<h1>привет</h1>")

# --- controllers (mirroring the oracle's controllers 1:1) ---------------

class DataController < ActionController::Base
  def data_default
    send_data("hello")
  end

  def data_filename
    send_data("pdf!", filename: "report.pdf")
  end

  def data_filename_utf8
    send_data("привет", filename: "отчёт.pdf")
  end

  def data_inline
    send_data("PNGDATA", type: "image/png", disposition: "inline", status: :created)
  end

  def data_no_disposition
    send_data("x", disposition: nil)
  end

  def file_default
    send_file(File.join(DIR, "notes.txt"))
  end

  def file_pdf
    send_file(File.join(DIR, "report.pdf"))
  end

  def file_unknown_ext
    send_file(File.join(DIR, "data.bin"))
  end

  def file_inline_status
    send_file(File.join(DIR, "notes.txt"),
      type: "text/plain; charset=utf-8", disposition: "inline", status: 404)
  end

  def file_url_based
    send_file(File.join(DIR, "notes.txt"), url_based_filename: true)
  end

  def file_utf8_name
    send_file(File.join(DIR, "страница.html"))
  end
end

class MissingFileController < ActionController::Base
  def show
    send_file(File.join(DIR, "nope.txt"))
  end
end

APP_DS = CRails::Application.new.tap do |app|
  app.routes.draw do
    get "/data_default", to: "data#data_default"
    get "/data_filename", to: "data#data_filename"
    get "/data_filename_utf8", to: "data#data_filename_utf8"
    get "/data_inline", to: "data#data_inline"
    get "/data_no_disposition", to: "data#data_no_disposition"
    get "/file_default", to: "data#file_default"
    get "/file_pdf", to: "data#file_pdf"
    get "/file_unknown_ext", to: "data#file_unknown_ext"
    get "/file_inline_status", to: "data#file_inline_status"
    get "/file_url_based", to: "data#file_url_based"
    get "/file_utf8_name", to: "data#file_utf8_name"
    get "/missing_route", to: "missing_file#show"
  end
end

module SpecDS
  class_property addr : Socket::IPAddress?
end

ds_server = HTTP::Server.new { |ctx| APP_DS.call(ctx) }
SpecDS.addr = ds_server.bind_tcp("127.0.0.1", 0)
spawn { ds_server.listen }
sleep 50.milliseconds

def ds_call(path : String) : String
  addr = SpecDS.addr.not_nil!
  response = HTTP::Client.new(addr.address, addr.port) do |client|
    client.exec(HTTP::Request.new("GET", path))
  end
  hs = response.headers
  [response.status_code,
   hs["Content-Type"]? || "",
   hs["Content-Disposition"]? || "",
   hs["Content-Transfer-Encoding"]? || "",
   "", # CL: приложение не ставит (стрим) — на проводе его добавляет сервер
   response.body? || ""].join("|")
end

describe "data streaming (actionpack 8.1.4 oracle)" do
  it "data_default" do
    ds_call("/data_default").should eq DS_EXPECTED["data_default"]
  end

  it "data_filename" do
    ds_call("/data_filename").should eq DS_EXPECTED["data_filename"]
  end

  it "data_filename_utf8" do
    ds_call("/data_filename_utf8").should eq DS_EXPECTED["data_filename_utf8"]
  end

  it "data_inline" do
    ds_call("/data_inline").should eq DS_EXPECTED["data_inline"]
  end

  it "data_no_disposition" do
    ds_call("/data_no_disposition").should eq DS_EXPECTED["data_no_disposition"]
  end

  it "file_default" do
    ds_call("/file_default").should eq DS_EXPECTED["file_default"]
  end

  it "file_pdf" do
    ds_call("/file_pdf").should eq DS_EXPECTED["file_pdf"]
  end

  it "file_unknown_ext" do
    ds_call("/file_unknown_ext").should eq DS_EXPECTED["file_unknown_ext"]
  end

  it "file_inline_status" do
    ds_call("/file_inline_status").should eq DS_EXPECTED["file_inline_status"]
  end

  it "file_url_based" do
    ds_call("/file_url_based").should eq DS_EXPECTED["file_url_based"]
  end

  it "file_utf8_name" do
    ds_call("/file_utf8_name").should eq DS_EXPECTED["file_utf8_name"]
  end

  it "file_missing" do
    # класс исключения — как в оракуле; railties-лестница маппит в 404
    io = IO::Memory.new
    ctx = HTTP::Server::Context.new(
      HTTP::Request.new("GET", "/nope"), HTTP::Server::Response.new(io))
    ctrl = MissingFileController.new(ctx)
    ctrl.__set_params({} of String => String)
    expect_raises(ActionController::MissingFile) { ctrl.__run_action("show") }
    ("raise:" + "ActionController::MissingFile").should eq DS_EXPECTED["file_missing"]
  end

  it "file_missing_maps_to_404" do
    # rescue_responses Rails: ActionController::MissingFile => :not_found
    ds_call("/missing_route")[0..2].should eq "404"
  end
end

# Documented deviations (also in src/data_streaming.cr):
# - Range requests for send_file are P2 (Rack::Files slice).
# - MIME inference is a Rack::Mime subset; type: is a String.
# - Content-Length is added by HTTP::Server, not the app (matches the
#   oracle's streaming behavior).
