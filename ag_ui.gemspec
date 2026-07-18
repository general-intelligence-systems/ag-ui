# frozen_string_literal: true

require_relative 'lib/ag_ui/version'

Gem::Specification.new do |spec|
  spec.name          = 'ag_ui'
  spec.version       = AgUi::VERSION
  spec.authors       = ['AgUi Contributors']
  spec.summary       = 'AG-UI protocol server'
  spec.description   = 'Ruby server implementation of the AG-UI protocol ' \
                       '(SSE event streaming, run loop, client-tool round-trips, A2UI) ' \
                       'for driving CopilotKit frontends from Rack/Falcon.'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 3.3'

  spec.files         = Dir['lib/**/*.rb', 'data/**/*']
  spec.require_paths = ['lib']

  spec.add_dependency 'async', '~> 2.0'
  spec.add_dependency 'protocol-http', '~> 0.62'
  spec.add_dependency 'rack', '~> 3.0'
  spec.add_dependency 'json_schemer', '~> 2.5'
  spec.add_dependency 'brute', '~> 3.0'

  # ruby_llm is the reference engine but the run loop only touches it through
  # the terminal proc — keep the gem LLM-agnostic (brute's rule).
  spec.add_development_dependency 'ruby_llm'
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'falcon', '~> 0.55'
  spec.add_development_dependency 'ratalada', '~> 1.0'
  spec.add_development_dependency 'rubocop', '~> 1.88'
  spec.add_development_dependency 'scampi', '~> 1.0'
  spec.add_development_dependency 'lefthook', '~> 2.1'
end
