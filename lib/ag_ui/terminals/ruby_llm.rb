# frozen_string_literal: true

require "bundler/setup"
require "securerandom"
require "ag_ui"
require "ruby_llm"

module AgUi
  module Terminals
    # The ruby_llm terminal — the LLM call at the bottom of the brute
    # pipeline. NOT required by lib/ag_ui.rb (the gem core stays
    # LLM-agnostic); opt in with:
    #
    #   require "ag_ui/terminals/ruby_llm"
    #
    #   RubyLLM.configure { |c| c.anthropic_api_key = ENV["ANTHROPIC_API_KEY"] }
    #   terminal = AgUi::Terminals::RubyLLM.new
    #   agent = Brute.agent.use(...).run(terminal)   # standard Brute agent
    #
    # One assistant turn per call: seeds the chat from env[:messages]
    # (including prior tool-call turns), registers env[:tools] as
    # schema-only CLIENT tools (they halt — never execute server-side),
    # streams text deltas into env[:events], then appends either the
    # assistant text or the assistant tool-call message to env[:messages]
    # for the ToolRouter to route.
    #
    # Accepts the host app's "anthropic/claude-sonnet-4-5" env form or a bare
    # ruby_llm model id.
    class RubyLLM
      # thinking: {effort:} or {budget:} enables extended thinking
      # (ruby_llm with_thinking); its deltas stream as REASONING_* events.
      def initialize(model: "anthropic/claude-sonnet-4-5", thinking: nil, chat_factory: nil)
        @provider, @model = split_model(model)
        @thinking = thinking
        @chat_factory = chat_factory || default_chat_factory
      end

      def call(env)
        chat = @chat_factory.call(model: @model, provider: @provider)
        if @thinking
          chat.with_thinking(**@thinking)
        end
        register_client_tools(chat, env[:tools])
        apply_tool_choice(chat, env)
        seed(chat, env[:messages])

        emitter = TurnEmitter.new(env[:events])
        chat.complete do |chunk|
          thinking = chunk.thinking
          if thinking&.text
            emitter.thinking_delta(thinking.text.to_s)
          end
          emitter.text_delta(chunk.content.to_s)
        end
        emitter.finish

        conclude(chat, env)
        env
      end

      def to_proc
        method(:call).to_proc
      end

      # A client tool: full schema for the provider, no server execution.
      # When the model calls it, execution "halts" ruby_llm's auto tool
      # loop — the assistant tool-call message is already in chat.messages
      # and the browser owns the actual execution (doc 03 multi-run model).
      class ClientTool < ::RubyLLM::Tool
        def initialize(name:, description:, parameters:)
          @client_name = name
          @client_description = description
          @client_schema = parameters
          super()
        end

        def name = @client_name
        def description = @client_description
        def params_schema = @client_schema

        # Bypass arg validation entirely — the browser is the executor
        # and the next run carries its result back in history.
        def call(_args)
          halt("(deferred to client)")
        end
      end

      # Emits the turn's reasoning + text phases lazily: nothing opens
      # until its first non-empty delta (tool-call-only turns produce no
      # empty bubbles), and reasoning closes as soon as text begins —
      # providers stream thinking strictly before the answer.
      class TurnEmitter
        def initialize(events)
          @events = events
          @text_id = SecureRandom.uuid
          @reasoning_id = SecureRandom.uuid
          @text_started = false
          @reasoning_open = false
        end

        def thinking_delta(text)
          unless text.empty?
            open_reasoning
            @events << {
              type: :reasoning_message_content,
              data: { message_id: @reasoning_id, delta: text },
            }
          end
        end

        def text_delta(text)
          unless text.empty?
            close_reasoning
            unless @text_started
              @events << { type: :text_message_start, data: { message_id: @text_id } }
              @text_started = true
            end
            @events << {
              type: :text_message_content,
              data: { message_id: @text_id, delta: text },
            }
          end
        end

        def finish
          close_reasoning
          if @text_started
            @events << { type: :text_message_end, data: { message_id: @text_id } }
          end
        end

        private

          def open_reasoning
            unless @reasoning_open
              @events << { type: :reasoning_start, data: { message_id: @reasoning_id } }
              @events << { type: :reasoning_message_start, data: { message_id: @reasoning_id } }
              @reasoning_open = true
            end
          end

          def close_reasoning
            if @reasoning_open
              @events << { type: :reasoning_message_end, data: { message_id: @reasoning_id } }
              @events << { type: :reasoning_end, data: { message_id: @reasoning_id } }
              @reasoning_open = false
            end
          end
      end

      private

        def split_model(model)
          if model.include?("/")
            provider, id = model.split("/", 2)
            [provider.to_sym, id]
          else
            [:anthropic, model]
          end
        end

        def default_chat_factory
          ->(model:, provider:) { ::RubyLLM.chat(model: model, provider: provider) }
        end

        # forwardedProps.toolChoice ({type: "function", function: {name}})
        # forces the named tool — the suggestions engine relies on this to
        # force copilotkitSuggest.
        def apply_tool_choice(chat, env)
          props = env[:forwarded_props]
          choice = props.is_a?(Hash) ? props["toolChoice"] : nil
          name = choice.is_a?(Hash) ? choice.dig("function", "name") : nil
          if name
            chat.with_tools(choice: name)
          end
        end

        def register_client_tools(chat, tools)
          (tools || []).each do |tool|
            chat.with_tool(
              ClientTool.new(
                name: dig_tool(tool, "name"),
                description: dig_tool(tool, "description"),
                parameters: dig_tool(tool, "parameters"),
              ),
            )
          end
        end

        # RunAgentInput.tools arrive as JsonSchema Definitions; accept
        # plain wire hashes too.
        def dig_tool(tool, key)
          if tool.respond_to?(:to_h)
            tool.to_h[key]
          else
            tool[key]
          end
        end

        # Seed the chat from the brute log. System content goes through
        # with_instructions (providers hoist it correctly); assistant
        # tool-call turns and tool results are replayed so the model sees
        # its prior calls and doesn't repeat them.
        def seed(chat, messages)
          messages.each do |message|
            case message.role
            when :system
              chat.with_instructions(message.content.to_s, append: true)
            when :user
              chat.add_message(role: :user, content: user_content(message.content))
            when :assistant
              seed_assistant(chat, message)
            when :tool
              chat.add_message(
                role: :tool,
                content: message.content.to_s,
                tool_call_id: message.tool_call_id,
              )
            end
          end
        end

        # Multimodal user content (InputContent part arrays, preserved by
        # Messages.to_brute) becomes a ruby_llm Content: text parts joined,
        # media parts attached — url sources as-is, base64 data sources as
        # io-like attachments named from their mime type.
        def user_content(content)
          if content.is_a?(Array)
            text = content.filter_map do |part|
              if part["type"] == "text"
                part["text"]
              end
            end
            rich = ::RubyLLM::Content.new(text.join("\n"))
            content.each do |part|
              attach_part(rich, part)
            end
            rich
          else
            content.to_s
          end
        end

        def attach_part(rich, part)
          source = part["source"]
          if source.is_a?(Hash)
            case source["type"]
            when "url"
              rich.add_attachment(source["value"].to_s)
            when "data"
              io = StringIO.new(source["value"].to_s.unpack1("m"))
              rich.add_attachment(io, filename: data_filename(source))
            end
          end
        end

        def data_filename(source)
          ext = source["mimeType"].to_s.split("/").last.to_s
          if ext.empty?
            "attachment.bin"
          else
            "attachment.#{ext}"
          end
        end

        def seed_assistant(chat, message)
          if message.tool_call?
            tool_calls = message.tool_calls.to_h do |tc|
              [tc.id, ::RubyLLM::ToolCall.new(id: tc.id, name: tc.name, arguments: tc.arguments)]
            end
            chat.add_message(role: :assistant, content: message.content.to_s, tool_calls: tool_calls)
          else
            chat.add_message(role: :assistant, content: message.content.to_s)
          end
        end

        # After the turn: did the model end on tool calls or text? The
        # halting ClientTool leaves the assistant tool-call message in
        # chat.messages (followed by the synthetic halt result) — surface
        # it as a brute message for the ToolRouter.
        def conclude(chat, env)
          assistant = chat.messages.reverse.find { |m| m.role == :assistant }

          if assistant&.tool_call?
            env[:messages] << Brute::Message.new(
              role: :assistant,
              content: assistant.content.to_s,
              tool_calls: assistant.tool_calls.each_value.map do |tc|
                { id: tc.id, name: tc.name, arguments: tc.arguments }
              end,
            )
          else
            env[:messages].assistant(assistant ? assistant.content.to_s : "")
          end
        end
    end
  end
end

__END__

describe "AgUi::Terminals::RubyLLM" do
  fake_message = Struct.new(:role, :content, :tool_calls, keyword_init: true) do
    def tool_call?
      !tool_calls.nil? && !tool_calls.empty?
    end
  end

  fake_chat_class = Class.new do
    attr_reader :instructions, :seeded, :tools, :messages, :thinking_config

    FakeChunk = Struct.new(:content, :thinking)
    FakeThinking = Struct.new(:text)

    def initialize(chunks: [], final: "", tool_calls: nil, thinking_chunks: [])
      @chunks = chunks
      @thinking_chunks = thinking_chunks
      @final = final
      @tool_calls = nil
      @final_tool_calls = tool_calls
      @instructions = []
      @seeded = []
      @tools = []
      @messages = []
      @thinking_config = nil
    end

    def with_thinking(**config)
      @thinking_config = config
      self
    end

    def with_instructions(text, append: false)
      @instructions << text
      self
    end

    def with_tool(tool)
      @tools << tool
      self
    end

    attr_reader :tool_choice

    def with_tools(*tools, choice: nil, **)
      @tools.concat(tools)
      @tool_choice = choice
      self
    end

    def add_message(attributes)
      @seeded << attributes
      @messages << Struct.new(:role, :content, :tool_calls, keyword_init: true) do
        def tool_call?
          !tool_calls.nil? && !tool_calls.empty?
        end
      end.new(role: attributes[:role], content: attributes[:content], tool_calls: attributes[:tool_calls])
      self
    end

    def complete(&block)
      @thinking_chunks.each { |t| block.call(FakeChunk.new(nil, FakeThinking.new(t))) }
      @chunks.each { |c| block.call(FakeChunk.new(c, nil)) }
      add_message(role: :assistant, content: @final, tool_calls: @final_tool_calls)
      @messages.last
    end
  end

  build_env = -> do
    { messages: Brute.log, events: [], metadata: {}, current_iteration: 1 }
  end

  it "streams deltas into env[:events] and appends the assistant message" do
    fake = fake_chat_class.new(chunks: ["Hel", "", "lo"], final: "Hello")
    terminal = AgUi::Terminals::RubyLLM.new(chat_factory: ->(**) { fake })

    env = build_env.()
    env[:messages].user("hi")
    terminal.call(env)

    types = env[:events].map { |e| e[:type] }
    types.should == [:text_message_start, :text_message_content, :text_message_content, :text_message_end]
    env[:events][1][:data][:delta].should == "Hel"

    env[:messages].last.role.should == :assistant
    env[:messages].last.content.should == "Hello"
  end

  it "registers env[:tools] as schema-only halting client tools" do
    fake = fake_chat_class.new(final: "ok")
    terminal = AgUi::Terminals::RubyLLM.new(chat_factory: ->(**) { fake })

    env = build_env.()
    env[:tools] = [{ "name" => "navigate", "description" => "Go somewhere",
                     "parameters" => { "type" => "object" } }]
    terminal.call(env)

    tool = fake.tools.first
    tool.name.should == "navigate"
    tool.description.should == "Go somewhere"
    tool.params_schema.should == { "type" => "object" }
    tool.call({ "path" => "/x" }).should.be.kind_of(::RubyLLM::Tool::Halt)
  end

  it "surfaces a tool-call turn as a brute assistant message with tool_calls" do
    tool_calls = {
      "tc1" => ::RubyLLM::ToolCall.new(id: "tc1", name: "navigate",
                                       arguments: { "path" => "/data" }),
    }
    fake = fake_chat_class.new(final: nil, tool_calls: tool_calls)
    terminal = AgUi::Terminals::RubyLLM.new(chat_factory: ->(**) { fake })

    env = build_env.()
    env[:messages].user("go to data")
    terminal.call(env)

    # No text events for a tool-only turn (lazy start).
    env[:events].should == []

    last = env[:messages].last
    last.tool_call?.should.be.true
    last.tool_calls.first.id.should == "tc1"
    last.tool_calls.first.arguments.should == { "path" => "/data" }
  end

  it "seeds prior tool-call turns and tool results back into the chat" do
    fake = fake_chat_class.new(final: "done")
    terminal = AgUi::Terminals::RubyLLM.new(chat_factory: ->(**) { fake })

    env = build_env.()
    env[:messages] << Brute::Message.new(role: :user, content: "go")
    env[:messages] << Brute::Message.new(
      role: :assistant, content: nil,
      tool_calls: [{ id: "tc1", name: "navigate", arguments: { "path" => "/data" } }],
    )
    env[:messages] << Brute::Message.new(role: :tool, content: "{\"ok\":true}", tool_call_id: "tc1")
    terminal.call(env)

    assistant_seed = fake.seeded[1]
    assistant_seed[:role].should == :assistant
    assistant_seed[:tool_calls]["tc1"].name.should == "navigate"

    tool_seed = fake.seeded[2]
    tool_seed[:role].should == :tool
    tool_seed[:tool_call_id].should == "tc1"
  end

  it "forces the tool named by forwardedProps.toolChoice" do
    fake = fake_chat_class.new(final: "ok")
    terminal = AgUi::Terminals::RubyLLM.new(chat_factory: ->(**) { fake })

    env = build_env.()
    env[:forwarded_props] = {
      "toolChoice" => { "type" => "function", "function" => { "name" => "copilotkitSuggest" } },
    }
    terminal.call(env)

    fake.tool_choice.should == "copilotkitSuggest"
  end

  it "streams thinking deltas as a reasoning phase closed before text" do
    fake = fake_chat_class.new(
      thinking_chunks: ["Let me ", "think..."],
      chunks: ["The answer"],
      final: "The answer",
    )
    terminal = AgUi::Terminals::RubyLLM.new(thinking: { budget: 1024 }, chat_factory: ->(**) { fake })

    env = build_env.()
    env[:messages].user("why?")
    terminal.call(env)

    fake.thinking_config.should == { budget: 1024 }
    env[:events].map { |e| e[:type] }.should == %i[
      reasoning_start reasoning_message_start
      reasoning_message_content reasoning_message_content
      reasoning_message_end reasoning_end
      text_message_start text_message_content text_message_end
    ]

    reasoning_ids = env[:events].first(6).map { |e| e[:data][:message_id] }.uniq
    reasoning_ids.length.should == 1
    env[:events].last[:data][:message_id].should.not == reasoning_ids.first
  end

  it "seeds multimodal user content as ruby_llm Content with attachments" do
    fake = fake_chat_class.new(final: "ok")
    terminal = AgUi::Terminals::RubyLLM.new(chat_factory: ->(**) { fake })

    png = ["\x89PNG fake"].pack("m0")
    env = build_env.()
    env[:messages] << Brute::Message.new(role: :user, content: [
      { "type" => "text", "text" => "what is this?" },
      { "type" => "image", "source" => { "type" => "data", "value" => png, "mimeType" => "image/png" } },
      { "type" => "document", "source" => { "type" => "url", "value" => "http://x/spec.pdf" } },
    ])
    terminal.call(env)

    content = fake.seeded.first[:content]
    content.should.be.kind_of(::RubyLLM::Content)
    content.text.should == "what is this?"
    content.attachments.length.should == 2
    content.attachments.first.filename.should == "attachment.png"
  end

  it "splits host-app-style provider/model ids and defaults to anthropic" do
    captured = []
    factory = ->(model:, provider:) do
      captured << [provider, model]
      fake_chat_class.new(final: "ok")
    end

    AgUi::Terminals::RubyLLM.new(model: "anthropic/claude-sonnet-4-5", chat_factory: factory)
      .call(build_env.())
    AgUi::Terminals::RubyLLM.new(model: "claude-sonnet-4-5", chat_factory: factory)
      .call(build_env.())
    captured.should == [[:anthropic, "claude-sonnet-4-5"], [:anthropic, "claude-sonnet-4-5"]]
  end

  it "drives the full client-tool run through a standard Brute agent + ToolRouter" do
    tool_calls = {
      "tc1" => ::RubyLLM::ToolCall.new(id: "tc1", name: "navigate",
                                       arguments: { "path" => "/data" }),
    }
    fake = fake_chat_class.new(final: nil, tool_calls: tool_calls)
    terminal = AgUi::Terminals::RubyLLM.new(chat_factory: ->(**) { fake })

    app = AgUi.agent(agent_id: "default") do |env|
      input = env["ag_ui.input"]
      agent = Brute.agent
                   .use(AgUi::Middleware::SystemPrompt, prompt: "Be terse.", context: input.context)
                   .use(AgUi::Middleware::ForwardedProps, props: input.forwarded_props)
                   .use(Brute::Middleware::Loop::ToolResult)
                   .use(Brute::Middleware::MaxIterations, max_iterations: 10)
                   .use(AgUi::Middleware::ToolRouter, tools: input.tools, server_tools: [])
                   .run(terminal)
      env["ag_ui.stream"].open(thread_id: input.thread_id, run_id: input.run_id) do |stream|
        stream.run_started
        agent.start(AgUi::Messages.to_brute(input.messages), events: AgUi::EventBridge.new(stream))
        stream.run_finished
      rescue => e
        stream.run_error(message: e.message, code: e.class.name)
      end
    end

    body = JSON.generate({
      "threadId" => "t1", "runId" => "r1", "state" => nil,
      "messages" => [{ "id" => "u1", "role" => "user", "content" => "go to data" }],
      "tools" => [{ "name" => "navigate", "description" => "Go", "parameters" => { "type" => "object" } }],
      "context" => [], "forwardedProps" => nil,
    })
    _status, _headers, stream = app.call({
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/agent/default/run",
      "rack.input" => StringIO.new(body),
    })

    frames = []
    while (chunk = stream.read)
      frames << JSON.parse(chunk.sub(/\Adata: /, "").strip)
    end

    frames.map { |f| f["type"] }.should == %w[
      RUN_STARTED TOOL_CALL_START TOOL_CALL_ARGS TOOL_CALL_END RUN_FINISHED
    ]
    frames[1]["toolCallId"].should == "tc1"
    frames[1]["toolCallName"].should == "navigate"
    frames[2]["delta"].should == "{\"path\":\"/data\"}"

    # Plain RUN_FINISHED — no result, no outcome (doc 09 §4).
    frames.last.should == { "type" => "RUN_FINISHED", "threadId" => "t1", "runId" => "r1" }
  end
end
