# frozen_string_literal: true

require "bundler/setup"
require "ag_ui"

module AgUi
  module Middleware
    # Exposes RunAgentInput.forwardedProps on the turn env so downstream
    # middleware and the terminal can honor client-driven knobs — most
    # importantly `toolChoice` ({type: "function", function: {name}}),
    # which the suggestions engine uses to force `copilotkitSuggest`.
    class ForwardedProps
      def initialize(app, props: nil)
        @app = app
        @props = props
      end

      def call(env)
        env[:forwarded_props] = @props
        @app.call(env)
      end
    end
  end
end

__END__

describe "AgUi::Middleware::ForwardedProps" do
  it "exposes the props on env" do
    seen = nil
    mw = AgUi::Middleware::ForwardedProps.new(
      ->(env) { seen = env[:forwarded_props] },
      props: { "toolChoice" => { "function" => { "name" => "copilotkitSuggest" } } },
    )
    mw.call({})
    seen.dig("toolChoice", "function", "name").should == "copilotkitSuggest"
  end
end
