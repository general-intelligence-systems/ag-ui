# frozen_string_literal: true

require "bundler/setup"
require "net/http"
require "uri"
require "ag_ui"

module AgUi
  module A2ui
    # The A2UI component catalog — the app's own UI vocabulary, served by
    # the frontend (e.g. GET /api/copilotkit/catalog) and fetched once at
    # boot, mirroring the Node sidecar (doc 09 §5): 20 retries x 3s, and
    # on total failure A2UI DEGRADES (tool still injected, no schema)
    # rather than failing the boot.
    #
    #   catalog = AgUi::A2ui::Catalog.fetch(url: ENV["AI_CATALOG_URL"])
    #   catalog&.catalog_id  #=> "host://ai-catalog"
    #
    Catalog = Data.define(:catalog_id, :components) do
      # Wire shape: { "catalogId" => "...", "components" => {...} }
      def self.from_wire(data)
        unless data.is_a?(Hash) && data["catalogId"] && data["components"]
          raise ArgumentError, "malformed catalog: expected catalogId + components"
        end

        new(catalog_id: data["catalogId"], components: data["components"])
      end

      def self.fetch(url:, retries: 20, interval: 3, http: nil, logger: Console)
        http ||= ->(u) { Net::HTTP.get_response(URI(u)) }

        attempt = 0
        loop do
          attempt += 1
          begin
            response = http.call(url)
            unless response.is_a?(Net::HTTPSuccess)
              raise "HTTP #{response.code}"
            end

            catalog = from_wire(JSON.parse(response.body))
            logger.info(
              self,
              "loaded A2UI catalog #{catalog.catalog_id} " \
              "(#{catalog.components.length} components) from #{url}",
            )
            break catalog
          rescue => e
            if attempt >= retries
              logger.warn(
                self,
                "A2UI catalog unreachable after #{attempt} attempts " \
                "(#{e.message}) — degrading (tool without schema)",
              )
              break nil
            end
            sleep interval
          end
        end
      end
    end
  end
end

__END__

describe "AgUi::A2ui::Catalog" do
  ok_body = JSON.generate({
    "catalogId" => "host://ai-catalog",
    "components" => { "Card" => { "description" => "A card", "props" => {} } },
  })

  fake_response = Struct.new(:body, :code) do
    def is_a?(klass) = klass == Net::HTTPSuccess || super
  end

  it "parses the wire shape" do
    catalog = AgUi::A2ui::Catalog.from_wire(JSON.parse(ok_body))
    catalog.catalog_id.should == "host://ai-catalog"
    catalog.components.keys.should == ["Card"]
  end

  it "rejects malformed catalogs" do
    lambda { AgUi::A2ui::Catalog.from_wire({ "nope" => 1 }) }.should.raise(ArgumentError)
  end

  it "fetches with retries and returns the catalog" do
    calls = 0
    http = ->(_url) do
      calls += 1
      raise "conn refused" if calls < 3

      fake_response.new(ok_body, "200")
    end

    catalog = AgUi::A2ui::Catalog.fetch(url: "http://x/catalog", retries: 5, interval: 0, http: http)
    catalog.catalog_id.should == "host://ai-catalog"
    calls.should == 3
  end

  it "degrades to nil after exhausting retries" do
    http = ->(_url) { raise "conn refused" }
    AgUi::A2ui::Catalog.fetch(url: "http://x/catalog", retries: 2, interval: 0, http: http)
      .should.be.nil
  end
end
