# frozen_string_literal: true

require "bundler/setup"
require "ag_ui"

module AgUi
  class Server
    # Builds the GET /info payload — the envelope the CopilotKit client
    # fetches on mount to discover agents and feature-detect capabilities.
    # Shape extracted verbatim from @copilotkit/runtime's
    # get-runtime-info.mjs (docs/09-ground-truth-host-app.md §1).
    #
    # The client feature-detects A2UI from the TOP-LEVEL `a2uiEnabled`
    # flag; when enabled, the optional `a2ui: {enabled: true}` detail
    # object rides along.
    module Info
      # The runtime version the client was built against; advertise the
      # same so version-gated client behaviour matches the Node sidecar.
      VERSION_PARITY = "1.62.2"

      class << self
        def payload(agent_id: "default", description: nil, a2ui_enabled: false, overrides: {})
          agent = { "name" => agent_id, "className" => "BuiltInAgent" }
          unless description.nil?
            agent["description"] = description
          end

          base = {
            "version" => VERSION_PARITY,
            "agents" => { agent_id => agent },
            "audioFileTranscriptionEnabled" => false,
            "mode" => "sse",
            "threadEndpoints" => {
              "list" => false,
              "inspect" => false,
              "mutations" => false,
              "realtimeMetadata" => false,
            },
            "a2uiEnabled" => a2ui_enabled,
            "openGenerativeUIEnabled" => false,
            "telemetryDisabled" => true,
          }

          if a2ui_enabled
            base["a2ui"] = { "enabled" => true }
          end

          base.merge(overrides)
        end
      end
    end
  end
end

__END__

describe "AgUi::Server::Info" do
  it "matches the Node runtime envelope for the default agent" do
    payload = AgUi::Server::Info.payload

    payload["version"].should == "1.62.2"
    payload["agents"].should == { "default" => { "name" => "default", "className" => "BuiltInAgent" } }
    payload["mode"].should == "sse"
    payload["a2uiEnabled"].should == false
    payload.key?("a2ui").should == false
    payload["threadEndpoints"].should == {
      "list" => false, "inspect" => false, "mutations" => false, "realtimeMetadata" => false,
    }
  end

  it "advertises a2ui via the top-level flag plus detail object" do
    payload = AgUi::Server::Info.payload(a2ui_enabled: true)
    payload["a2uiEnabled"].should == true
    payload["a2ui"].should == { "enabled" => true }
  end

  it "includes agent description when given and applies overrides" do
    payload = AgUi::Server::Info.payload(
      agent_id: "host-app", description: "Studio assistant",
      overrides: { "telemetryDisabled" => false },
    )
    payload["agents"]["host-app"]["description"].should == "Studio assistant"
    payload["telemetryDisabled"].should == false
  end
end
