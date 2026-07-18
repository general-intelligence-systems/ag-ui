# frozen_string_literal: true

require "bundler/setup"
require "securerandom"
require "ag_ui"

module AgUi
  module Middleware
    # A2UI (Tier-3 generative UI) — the Ruby port of CopilotKit's
    # @ag-ui/a2ui-middleware transform (doc 09 §6).
    #
    # Way in:
    #   - injects the `render_a2ui` tool into env[:tools] (STATIC schema —
    #     the catalog does NOT shape it)
    #   - appends the catalog's component schema to the conversation as a
    #     system message (that's how the model learns the vocabulary)
    #
    # Way out, for each `render_a2ui` call the model made:
    #   - converts the call args into an ACTIVITY_SNAPSHOT carrying
    #     `a2ui_operations` (createSurface once per surface, then
    #     updateComponents / updateDataModel), flat wire shape,
    #     activityType "a2ui-surface", replace: true
    #   - emits a synthetic TOOL_CALL_RESULT ({"status":"rendered"}) so the
    #     next run's history shows the model its call completed
    #
    # The TOOL_CALL_* events themselves pass through (ToolRouter emits
    # them) and the run still ends — same multi-run model as client tools;
    # the activity events are what the canvas renders.
    #
    # Sits OUTSIDE ToolRouter in the pipeline:
    #   use SystemPrompt; use A2ui, catalog: catalog; use ToolRouter
    class A2ui
      TOOL_NAME = "render_a2ui"

      TOOL_DEFINITION = {
        "name" => TOOL_NAME,
        "description" =>
          "Render a dynamic A2UI v0.9 surface with structured parameters. " \
          "Follow the A2UI render tool usage guide provided in context.",
        "parameters" => {
          "type" => "object",
          "properties" => {
            "surfaceId" => {
              "type" => "string",
              "description" => "Unique surface identifier.",
            },
            "components" => {
              "type" => "array",
              "description" =>
                "A2UI v0.9 component array (flat format). The root component " \
                "must have id \"root\".",
              "items" => { "type" => "object" },
            },
            "data" => {
              "type" => "object",
              "description" =>
                "Initial data model for the surface. Written to the root path. " \
                "Use for pre-filling form values (e.g. {\"form\": {\"name\": \"Alice\"}}) " \
                "or providing data for components bound to data model paths.",
            },
          },
          "required" => %w[surfaceId components],
        },
      }.freeze

      SCHEMA_CONTEXT_PREAMBLE =
        "A2UI Component Schema — available components for generating UI " \
        "surfaces. Use these component names and properties when creating " \
        "A2UI operations."

      BASIC_CATALOG_ID = "https://a2ui.org/specification/v0_9/basic_catalog.json"

      def initialize(app, catalog: nil, default_catalog_id: nil)
        @app = app
        @catalog = catalog
        @default_catalog_id = default_catalog_id || catalog&.catalog_id
      end

      def call(env)
        env[:tools] = (env[:tools] || []) + [TOOL_DEFINITION]
        inject_catalog_schema(env)

        @app.call(env)

        last = env[:messages].last
        if last.respond_to?(:tool_call?) && last.tool_call?
          emitted_surfaces = Set.new
          last.tool_calls.each do |tool_call|
            if tool_call.name == TOOL_NAME
              render(env[:events], tool_call, emitted_surfaces)
            end
          end
        end

        env
      end

      private

        # A catalog can carry an id without component schemas (the app may
        # teach the model its vocabulary through the system prompt instead)
        # — only inject and validate against components when they exist.
        def catalog_components?
          @catalog && !@catalog.components.to_h.empty?
        end

        def inject_catalog_schema(env)
          if catalog_components?
            env[:messages].unshift(
              Brute::Message.new(
                role: :system,
                content: "#{SCHEMA_CONTEXT_PREAMBLE}\n#{JSON.generate(@catalog.components)}",
              ),
            )
          end
        end

        # Components are validated with the ported a2ui_toolkit semantics
        # (catalog membership, required props, child refs, cycles).
        # Bindings are NOT validated here — same as the Node middleware
        # (validateBindings: false): relative template paths resolve
        # per-item at render time and would false-positive.
        def render(events, tool_call, emitted_surfaces)
          args = tool_call.arguments
          surface_id = args["surfaceId"].to_s

          validation = ::AgUi::A2ui.validate_components(
            components: args["components"],
            data: args["data"].is_a?(Hash) ? args["data"] : {},
            catalog: catalog_components? ? { "components" => @catalog.components } : nil,
            validate_bindings: false,
          )

          if surface_id.empty? || !validation["valid"]
            failure = {
              "status" => "failed",
              "error" => "render_a2ui produced invalid components",
              "errors" => validation["errors"],
            }
            events << activity(tool_call, failure)
            events << result(tool_call, { "status" => "failed", "errors" => validation["errors"] })
          else
            ops = operations(args, surface_id, emitted_surfaces)
            events << activity(tool_call, { "a2ui_operations" => ops })
            events << result(tool_call, { "status" => "rendered" })
          end
        end

        # createSurface once per surface within the turn; updateComponents
        # always; updateDataModel when initial data was given.
        def operations(args, surface_id, emitted_surfaces)
          ops = []

          if emitted_surfaces.add?(surface_id)
            ops << {
              "version" => "v0.9",
              "createSurface" => { "surfaceId" => surface_id, "catalogId" => catalog_id },
            }
          end

          ops << {
            "version" => "v0.9",
            "updateComponents" => { "surfaceId" => surface_id, "components" => args["components"] },
          }

          if args["data"].is_a?(Hash) && !args["data"].empty?
            ops << {
              "version" => "v0.9",
              "updateDataModel" => { "surfaceId" => surface_id, "path" => "/", "value" => args["data"] },
            }
          end

          ops
        end

        def catalog_id
          @default_catalog_id || BASIC_CATALOG_ID
        end

        def activity(tool_call, content)
          {
            type: :activity_snapshot,
            data: {
              message_id: "a2ui-surface-#{tool_call.id}",
              activity_type: "a2ui-surface",
              content: content,
              replace: true,
            },
          }
        end

        def result(tool_call, content)
          {
            type: :tool_call_result,
            data: {
              message_id: SecureRandom.uuid,
              tool_call_id: tool_call.id,
              content: JSON.generate(content),
            },
          }
        end
    end
  end
end

__END__

describe "AgUi::Middleware::A2ui" do
  catalog = AgUi::A2ui::Catalog.new(
    catalog_id: "host://ai-catalog",
    components: { "Card" => { "description" => "A card", "props" => {} } },
  )

  render_call = ->(args) do
    Brute::Message.new(
      role: :assistant, content: nil,
      tool_calls: [{ id: "tc1", name: "render_a2ui", arguments: args }],
    )
  end

  it "injects the render_a2ui tool and the catalog schema system message" do
    seen = nil
    mw = AgUi::Middleware::A2ui.new(->(env) { seen = env }, catalog: catalog)
    mw.call({ messages: Brute.log, events: [], tools: [{ "name" => "navigate" }] })

    seen[:tools].map { |t| t["name"] }.should == %w[navigate render_a2ui]
    tool = seen[:tools].last
    tool["parameters"]["required"].should == %w[surfaceId components]

    schema_msg = seen[:messages].first
    schema_msg.role.should == :system
    schema_msg.content.should.include?("A2UI Component Schema")
    schema_msg.content.should.include?("Card")
  end

  it "keeps an id-only catalog prompt-driven: no schema message, structural validation" do
    id_only = AgUi::A2ui::Catalog.new(catalog_id: "app://cat", components: {})
    seen = nil
    terminal = ->(env) do
      seen = env
      env[:messages] << render_call.(
        "surfaceId" => "s1",
        "components" => [{ "id" => "root", "component" => "AnythingGoes" }],
      )
    end

    env = { messages: Brute.log, events: [], tools: [] }
    AgUi::Middleware::A2ui.new(terminal, catalog: id_only).call(env)

    seen[:messages].first.role.should == :assistant  # no schema system message
    env[:events][0][:data][:content].key?("a2ui_operations").should == true
    env[:events][0][:data][:content]["a2ui_operations"][0]["createSurface"]["catalogId"]
      .should == "app://cat"
  end

  it "injects the tool without a schema message when degraded (no catalog)" do
    seen = nil
    AgUi::Middleware::A2ui.new(->(env) { seen = env })
      .call({ messages: Brute.log, events: [], tools: [] })

    seen[:tools].map { |t| t["name"] }.should == ["render_a2ui"]
    seen[:messages].should == []
  end

  it "converts a render_a2ui call into activity + synthetic rendered result" do
    terminal = ->(env) do
      env[:messages] << render_call.(
        "surfaceId" => "s1",
        "components" => [{ "id" => "root", "component" => "Card" }],
        "data" => { "title" => "hi" },
      )
    end

    env = { messages: Brute.log, events: [], tools: [] }
    AgUi::Middleware::A2ui.new(terminal, catalog: catalog).call(env)

    activity = env[:events][0]
    activity[:type].should == :activity_snapshot
    activity[:data][:message_id].should == "a2ui-surface-tc1"
    activity[:data][:activity_type].should == "a2ui-surface"
    activity[:data][:replace].should == true

    ops = activity[:data][:content]["a2ui_operations"]
    ops[0]["createSurface"].should == { "surfaceId" => "s1", "catalogId" => "host://ai-catalog" }
    ops[1]["updateComponents"]["components"].first["id"].should == "root"
    ops[2]["updateDataModel"].should == { "surfaceId" => "s1", "path" => "/", "value" => { "title" => "hi" } }

    result = env[:events][1]
    result[:type].should == :tool_call_result
    result[:data][:tool_call_id].should == "tc1"
    result[:data][:content].should == "{\"status\":\"rendered\"}"
  end

  minimal_components = [{ "id" => "root", "component" => "Card" }]

  it "falls back to the basic catalog id when degraded" do
    terminal = ->(env) do
      env[:messages] << render_call.("surfaceId" => "s1", "components" => minimal_components)
    end

    env = { messages: Brute.log, events: [], tools: [] }
    AgUi::Middleware::A2ui.new(terminal).call(env)

    ops = env[:events][0][:data][:content]["a2ui_operations"]
    ops[0]["createSurface"]["catalogId"].should ==
      "https://a2ui.org/specification/v0_9/basic_catalog.json"
  end

  it "creates each surface once but updates on every call" do
    terminal = ->(env) do
      env[:messages] << Brute::Message.new(
        role: :assistant, content: nil,
        tool_calls: [
          { id: "tc1", name: "render_a2ui",
            arguments: { "surfaceId" => "s1", "components" => minimal_components } },
          { id: "tc2", name: "render_a2ui",
            arguments: { "surfaceId" => "s1", "components" => minimal_components } },
        ],
      )
    end

    env = { messages: Brute.log, events: [], tools: [] }
    AgUi::Middleware::A2ui.new(terminal, catalog: catalog).call(env)

    activities = env[:events].select { |e| e[:type] == :activity_snapshot }
    first_ops = activities[0][:data][:content]["a2ui_operations"]
    second_ops = activities[1][:data][:content]["a2ui_operations"]

    first_ops.map(&:keys).flatten.should.include?("createSurface")
    second_ops.map(&:keys).flatten.should.not.include?("createSurface")
  end

  it "ignores non-a2ui tool calls and marks malformed args failed" do
    terminal = ->(env) do
      env[:messages] << Brute::Message.new(
        role: :assistant, content: nil,
        tool_calls: [
          { id: "tc1", name: "navigate", arguments: { "path" => "/x" } },
          { id: "tc2", name: "render_a2ui", arguments: { "surfaceId" => "s1" } },
        ],
      )
    end

    env = { messages: Brute.log, events: [], tools: [] }
    AgUi::Middleware::A2ui.new(terminal, catalog: catalog).call(env)

    env[:events].length.should == 2
    env[:events][0][:data][:content]["status"].should == "failed"
    JSON.parse(env[:events][1][:data][:content])["status"].should == "failed"
  end

  it "rejects semantically invalid trees via the toolkit validator" do
    terminal = ->(env) do
      env[:messages] << render_call.(
        "surfaceId" => "s1",
        "components" => [
          { "id" => "root", "component" => "Mystery", "children" => ["ghost"] },
        ],
      )
    end

    env = { messages: Brute.log, events: [], tools: [] }
    AgUi::Middleware::A2ui.new(terminal, catalog: catalog).call(env)

    content = env[:events][0][:data][:content]
    content["status"].should == "failed"
    codes = content["errors"].map { |e| e["code"] }
    codes.should.include?("unknown_component")
    codes.should.include?("unresolved_child")
  end
end
