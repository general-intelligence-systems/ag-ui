# frozen_string_literal: true

require "bundler/setup"
require "console"
require "ag_ui"

module AgUi
  # The run loop: drives one AG-UI run through a brute turn pipeline.
  #
  # The terminal block is the LLM call (ruby_llm or anything else) — it
  # receives brute's env ({messages:, events:, ...}), streams deltas into
  # env[:events] (translated live to SSE by EventBridge) and appends the
  # assistant message to env[:messages]. The gem stays LLM-agnostic.
  #
  #   run_loop = AgUi::RunLoop.new(system_prompt: PROMPT) do |env|
  #     env[:events] << { type: :text_message_start, data: { message_id: id } }
  #     ... stream provider chunks ...
  #     env[:events] << { type: :text_message_end, data: { message_id: id } }
  #     env[:messages].assistant(full_text)
  #   end
  #
  #   app = AgUi.agent(agent_id: "default", &run_loop)
  #
  # Lifecycle per run (the AG-UI contract): RUN_STARTED first; then the
  # pipeline streams; then RUN_FINISHED — or RUN_ERROR if the pipeline
  # raised. Schema-validation failures are wire-contract bugs and re-raise
  # after RUN_ERROR so they fail loudly in dev.
  class RunLoop
    # a2ui: nil/false = off; an AgUi::A2ui::Catalog = on with that catalog;
    # true = on degraded (tool injected, no component schema).
    # server_tools: [{name:, description:, parameters:, handler:}] execute
    # inline and the turn loops (Loop::ToolResult) until the model answers
    # in text, a client tool defers to the browser, or max_iterations hits.
    def initialize(system_prompt: nil, validate: true, middleware: [], a2ui: nil,
                   server_tools: [], max_iterations: 10, &terminal)
      unless terminal
        raise ArgumentError, "RunLoop requires a terminal block (the LLM call)"
      end

      @system_prompt = system_prompt
      @validate = validate
      @middleware = middleware
      @a2ui = a2ui
      @server_tools = server_tools
      @max_iterations = max_iterations
      @terminal = terminal
    end

    def a2ui_enabled?
      !(@a2ui.nil? || @a2ui == false)
    end

    # AgUi.agent takes a block; RunLoop quacks like one.
    def to_proc
      run_loop = self
      proc { |rack_env| run_loop.handle(rack_env) }
    end

    def handle(rack_env)
      input = rack_env["ag_ui.input"]

      rack_env["ag_ui.stream"].open(
        thread_id: input.thread_id,
        run_id: input.run_id,
        validate: @validate,
      ) do |stream|
        stream.run_started
        run(stream, input)
      end
    end

    private

      def run(stream, input)
        pipeline(input).start(
          Messages.to_brute(input.messages),
          events: EventBridge.new(stream),
        )
        stream.run_finished
      rescue Protocol::JsonSchema::ValidationError => e
        Console.error(self, "wire-contract bug: #{e.message}", e)
        stream.run_error(message: "Internal error", code: "validation")
        raise
      rescue => e
        Console.error(self, "run failed: #{e.class}: #{e.message}", e)
        stream.run_error(message: e.message, code: e.class.name)
      end

      def pipeline(input)
        agent = Brute.agent
        agent.use(
          AgUi::Middleware::SystemPrompt,
          prompt: @system_prompt,
          context: input.context,
        )
        agent.use(AgUi::Middleware::ForwardedProps, props: input.forwarded_props)
        agent.use(Brute::Middleware::Loop::ToolResult)
        agent.use(Brute::Middleware::MaxIterations, max_iterations: @max_iterations)
        if a2ui_enabled?
          catalog = @a2ui.is_a?(AgUi::A2ui::Catalog) ? @a2ui : nil
          agent.use(AgUi::Middleware::A2ui, catalog: catalog)
        end
        agent.use(AgUi::Middleware::ToolRouter, tools: input.tools, server_tools: @server_tools)
        @middleware.each do |(klass, options)|
          agent.use(klass, **(options || {}))
        end
        agent.run(@terminal)
      end
  end
end

__END__

describe "AgUi::RunLoop" do
  minimal_input = JSON.generate({
    "threadId" => "t1", "runId" => "r1", "state" => nil,
    "messages" => [{ "id" => "u1", "role" => "user", "content" => "hi" }],
    "tools" => [], "context" => [{ "description" => "currentPath", "value" => "/data" }],
    "forwardedProps" => nil,
  })

  request = ->(app, body) do
    app.call({
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/agent/default/run",
      "rack.input" => StringIO.new(body),
    })
  end

  read_frames = ->(stream) do
    frames = []
    while (chunk = stream.read)
      frames << JSON.parse(chunk.sub(/\Adata: /, "").strip)
    end
    frames
  end

  it "streams a full run through a brute pipeline" do
    seen_env = nil
    run_loop = AgUi::RunLoop.new(system_prompt: "Be terse.") do |env|
      seen_env = env
      env[:events] << { type: :text_message_start, data: { message_id: "m1" } }
      env[:events] << { type: :text_message_content, data: { message_id: "m1", delta: "Hello" } }
      env[:events] << { type: :text_message_end, data: { message_id: "m1" } }
      env[:messages].assistant("Hello")
    end

    app = AgUi.agent(agent_id: "default", &run_loop)
    _status, _headers, body = request.(app, minimal_input)

    frames = read_frames.(body)
    frames.map { |f| f["type"] }.should == %w[
      RUN_STARTED TEXT_MESSAGE_START TEXT_MESSAGE_CONTENT TEXT_MESSAGE_END RUN_FINISHED
    ]

    # The pipeline saw: system prompt (with context addendum) + history.
    seen_env[:messages].map(&:role).should == [:system, :user, :assistant]
    seen_env[:messages].first.content.should.include?("Be terse.")
    seen_env[:messages].first.content.should.include?("currentPath: /data")
  end

  it "ends the run with RUN_ERROR when the terminal raises" do
    run_loop = AgUi::RunLoop.new { |_env| raise "provider exploded" }
    app = AgUi.agent(agent_id: "default", &run_loop)

    _status, _headers, body = request.(app, minimal_input)
    frames = read_frames.(body)

    frames.map { |f| f["type"] }.should == %w[RUN_STARTED RUN_ERROR]
    frames.last["message"].should == "provider exploded"
    frames.last["code"].should == "RuntimeError"
  end

  it "supports extra brute middleware" do
    marker = Class.new do
      def initialize(app, note:)
        @app = app
        @note = note
      end

      def call(env)
        env[:metadata][:note] = @note
        @app.call(env)
      end
    end

    seen = nil
    run_loop = AgUi::RunLoop.new(middleware: [[marker, { note: "hi" }]]) do |env|
      seen = env[:metadata][:note]
      env[:messages].assistant("ok")
    end

    request.(AgUi.agent(&run_loop), minimal_input)
    seen.should == "hi"
  end

  it "requires a terminal block" do
    lambda { AgUi::RunLoop.new }.should.raise(ArgumentError)
  end

  it "executes server tools inline and loops the turn to completion" do
    weather_tool = {
      name: "get_weather",
      description: "Weather for a city",
      parameters: { "type" => "object" },
      handler: ->(args) { { "city" => args["city"], "temp" => 21 } },
    }

    iterations = 0
    terminal = ->(env) do
      iterations += 1
      if iterations == 1
        env[:messages] << Brute::Message.new(
          role: :assistant, content: nil,
          tool_calls: [{ id: "tc1", name: "get_weather", arguments: { "city" => "Lisbon" } }],
        )
      else
        # The model sees its own call + the executed result.
        env[:messages].last.role.should == :tool
        env[:messages].last.content.should == "{\"city\":\"Lisbon\",\"temp\":21}"
        env[:events] << { type: :text_message_start, data: { message_id: "m2" } }
        env[:events] << { type: :text_message_content, data: { message_id: "m2", delta: "21C in Lisbon" } }
        env[:events] << { type: :text_message_end, data: { message_id: "m2" } }
        env[:messages].assistant("21C in Lisbon")
      end
    end

    run_loop = AgUi::RunLoop.new(server_tools: [weather_tool], &terminal)
    app = AgUi.agent(agent_id: "default", &run_loop)

    _status, _headers, stream = request.(app, minimal_input)
    frames = read_frames.(stream)

    iterations.should == 2
    frames.map { |f| f["type"] }.should == %w[
      RUN_STARTED
      TOOL_CALL_START TOOL_CALL_ARGS TOOL_CALL_END TOOL_CALL_RESULT
      TEXT_MESSAGE_START TEXT_MESSAGE_CONTENT TEXT_MESSAGE_END
      RUN_FINISHED
    ]
    frames[4]["content"].should == "{\"city\":\"Lisbon\",\"temp\":21}"
  end

  it "streams the full A2UI sequence when the model renders a surface" do
    catalog = AgUi::A2ui::Catalog.new(
      catalog_id: "host://ai-catalog",
      components: { "Card" => {} },
    )

    terminal = ->(env) do
      env[:tools].map { |t| t["name"] }.should.include?("render_a2ui")
      env[:messages].first.content.should.include?("A2UI Component Schema")

      env[:messages] << Brute::Message.new(
        role: :assistant, content: nil,
        tool_calls: [{ id: "tc9", name: "render_a2ui", arguments: {
          "surfaceId" => "s1",
          "components" => [{ "id" => "root", "component" => "Card" }],
        } }],
      )
    end

    run_loop = AgUi::RunLoop.new(a2ui: catalog, &terminal)
    app = AgUi.agent(agent_id: "default", &run_loop)

    _status, _headers, stream = request.(app, minimal_input)
    frames = read_frames.(stream)

    frames.map { |f| f["type"] }.should == %w[
      RUN_STARTED TOOL_CALL_START TOOL_CALL_ARGS TOOL_CALL_END
      ACTIVITY_SNAPSHOT TOOL_CALL_RESULT RUN_FINISHED
    ]

    snapshot = frames[4]
    snapshot["messageId"].should == "a2ui-surface-tc9"
    snapshot["activityType"].should == "a2ui-surface"
    snapshot["replace"].should == true
    snapshot["content"]["a2ui_operations"][0]["createSurface"]["catalogId"]
      .should == "host://ai-catalog"

    result = frames[5]
    result["toolCallId"].should == "tc9"
    result["content"].should == "{\"status\":\"rendered\"}"
  end
end
