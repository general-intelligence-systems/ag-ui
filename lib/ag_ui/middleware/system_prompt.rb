# frozen_string_literal: true

require "bundler/setup"
require "ag_ui"

module AgUi
  module Middleware
    # Brute-style turn middleware: prepends the agent's system prompt,
    # with the run's RunAgentInput.context entries appended as a context
    # addendum (useAgentContext — how the agent "sees" the current page).
    #
    # Skips entirely when the history already carries a system message
    # (the client can send its own via system/developer roles).
    class SystemPrompt
      def initialize(app, prompt: nil, context: nil)
        @app = app
        @prompt = prompt
        @context = context
      end

      def call(env)
        unless env[:messages].any? { |m| m.role == :system }
          content = [@prompt, context_addendum].compact.join("\n\n")
          unless content.empty?
            env[:messages].unshift(Brute::Message.new(role: :system, content: content))
          end
        end

        @app.call(env)
      end

      private

        def context_addendum(context = @context)
          if context.nil? || context.empty?
            nil
          else
            lines = context.map { |entry| "- #{entry.description}: #{entry.value}" }
            "Context shared by the application:\n#{lines.join("\n")}"
          end
        end
    end
  end
end

__END__

describe "AgUi::Middleware::SystemPrompt" do
  terminal = ->(env) { env }

  it "prepends the prompt as a system message" do
    mw = AgUi::Middleware::SystemPrompt.new(terminal, prompt: "Be terse.")
    env = { messages: Brute.log.tap { |l| l.user("hi") } }
    mw.call(env)

    env[:messages].first.role.should == :system
    env[:messages].first.content.should == "Be terse."
  end

  it "appends RunAgentInput.context entries as an addendum" do
    context = [
      AgUi::Protocol::JsonSchema["Context"].new(description: "currentPath", value: "/data"),
      AgUi::Protocol::JsonSchema["Context"].new(description: "user", value: "nathan"),
    ]
    mw = AgUi::Middleware::SystemPrompt.new(terminal, prompt: "Be terse.", context: context)
    env = { messages: Brute.log }
    mw.call(env)

    env[:messages].first.content.should.include?("Be terse.")
    env[:messages].first.content.should.include?("- currentPath: /data")
    env[:messages].first.content.should.include?("- user: nathan")
  end

  it "leaves history alone when a system message already exists" do
    mw = AgUi::Middleware::SystemPrompt.new(terminal, prompt: "Be terse.")
    env = { messages: Brute.log.tap { |l| l.system("existing") } }
    mw.call(env)

    env[:messages].length.should == 1
    env[:messages].first.content.should == "existing"
  end

  it "adds nothing when there is no prompt and no context" do
    mw = AgUi::Middleware::SystemPrompt.new(terminal)
    env = { messages: Brute.log }
    mw.call(env)

    env[:messages].should == []
  end
end
