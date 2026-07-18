# frozen_string_literal: true

require "bundler/setup"
require "ag_ui"

module AgUi
  module A2ui
    # A2UI error-recovery loop — Ruby port of the toolkit's recovery.py.
    #
    # The toolkit cannot bind/invoke a model, so the adapter supplies
    # `invoke_subagent` (its model call, receives (prompt, attempt) and
    # returns the render_a2ui args hash or nil) and `build_envelope` (its
    # prepared operations envelope). This module owns the validate→retry
    # loop using the SAME validate_components the middleware uses, so the
    # retry decision and the paint decision agree.
    module Recovery
      module_function

      # Default attempt cap (initial try + retries). Configurable per call.
      MAX_A2UI_ATTEMPTS = 3

      # Activity type the middleware/client use for the recovery status channel.
      A2UI_RECOVERY_ACTIVITY_TYPE = "a2ui_recovery"

      NO_TOOL_CALL_ERROR = {
        "code" => "empty_components",
        "path" => "components",
        "message" => "Sub-agent did not call render_a2ui",
      }.freeze

      # Render structured errors as a compact, model-readable list.
      def format_validation_errors(errors)
        errors.map { |e| "- [#{e["code"]}] #{e["path"]}: #{e["message"]}" }.join("\n")
      end

      # Append a fix-it block describing the prior attempt's errors.
      def augment_prompt_with_validation_errors(prompt, errors)
        if errors.empty?
          prompt
        else
          "#{prompt}\n\n## Previous attempt was invalid — fix these and regenerate:\n" \
            "#{format_validation_errors(errors)}\n"
        end
      end

      # Drive the validate→retry loop. Returns {"envelope", "attempts",
      # "ok"}: the validated envelope on success, or a structured
      # a2ui_recovery_exhausted envelope once the cap is hit. Never retries
      # an attempt whose components validated.
      def run_generation_with_recovery(base_prompt:, invoke_subagent:, build_envelope:,
                                       catalog: nil, config: nil, on_attempt: nil)
        max_attempts = (config || {})["maxAttempts"] || MAX_A2UI_ATTEMPTS
        attempts = []
        last_errors = []

        (1..max_attempts).each do |attempt|
          prompt = augment_prompt_with_validation_errors(base_prompt, last_errors)
          args = invoke_subagent.call(prompt, attempt)

          record =
            if args.nil? || args.empty?
              { "attempt" => attempt, "ok" => false, "errors" => [NO_TOOL_CALL_ERROR] }
            else
              components = args["components"].is_a?(Array) ? args["components"] : []
              data = args["data"].is_a?(Hash) ? args["data"] : {}
              result = Validate.validate_components(components: components, data: data, catalog: catalog)
              { "attempt" => attempt, "ok" => result["valid"], "errors" => result["errors"] }
            end

          attempts << record
          on_attempt&.call(record)

          if record["ok"]
            break { "envelope" => build_envelope.call(args), "attempts" => attempts, "ok" => true }
          end

          last_errors = record["errors"]
        end.then do |result|
          if result.is_a?(Hash)
            result
          else
            {
              "envelope" => exhausted_envelope(max_attempts, attempts),
              "attempts" => attempts,
              "ok" => false,
            }
          end
        end
      end

      def exhausted_envelope(max_attempts, attempts)
        JSON.generate(
          {
            "error" => "Failed to generate valid A2UI after #{max_attempts} attempt(s)",
            "code" => "a2ui_recovery_exhausted",
            "attempts" => attempts,
          },
        )
      end
    end
  end
end

__END__

describe "AgUi::A2ui::Recovery" do
  # Fixtures ported verbatim from the toolkit's test_recovery.py.
  recovery = AgUi::A2ui::Recovery

  catalog = { "components" => {
    "Row" => { "required" => ["children"] },
    "HotelCard" => { "required" => %w[name rating] },
  } }

  root = { "id" => "root", "component" => "Row",
           "children" => { "componentId" => "card", "path" => "/items" } }
  good_card = { "id" => "card", "component" => "HotelCard",
                "name" => { "path" => "name" }, "rating" => { "path" => "rating" } }
  bad_card = { "id" => "card", "component" => "HotelCard", "name" => { "path" => "name" } }

  good_args = { "surfaceId" => "s1", "components" => [root, good_card],
                "data" => { "items" => [{ "name" => "Ritz", "rating" => 4.8 }] } }
  bad_args = { "surfaceId" => "s1", "components" => [root, bad_card],
               "data" => { "items" => [{ "name" => "Ritz", "rating" => 4.8 }] } }

  build_envelope = ->(args) { JSON.generate({ "a2ui_operations" => args["components"] }) }

  it "exposes the upstream defaults" do
    recovery::MAX_A2UI_ATTEMPTS.should == 3
    recovery::A2UI_RECOVERY_ACTIVITY_TYPE.should == "a2ui_recovery"
  end

  it "augments prompts with a fix-it block only when there are errors" do
    errors = [{ "code" => "missing_required_prop", "path" => "components[1].rating",
                "message" => "missing required prop 'rating'" }]

    recovery.augment_prompt_with_validation_errors("BASE", []).should == "BASE"

    out = recovery.augment_prompt_with_validation_errors("BASE", errors)
    out.should.include?("BASE")
    out.should.include?("rating")
    out.should.include?(recovery.format_validation_errors(errors))
  end

  it "returns the envelope on a valid first attempt" do
    calls = []
    result = recovery.run_generation_with_recovery(
      base_prompt: "P", catalog: catalog,
      invoke_subagent: ->(_prompt, attempt) { calls << attempt; good_args },
      build_envelope: build_envelope,
    )

    result["ok"].should == true
    result["attempts"].length.should == 1
    calls.should == [1]
    JSON.parse(result["envelope"]).key?("a2ui_operations").should == true
  end

  it "recovers on the second attempt with error feedback in the prompt" do
    prompts = []
    result = recovery.run_generation_with_recovery(
      base_prompt: "P", catalog: catalog,
      invoke_subagent: ->(prompt, attempt) { prompts << prompt; attempt == 1 ? bad_args : good_args },
      build_envelope: build_envelope,
    )

    result["ok"].should == true
    result["attempts"].length.should == 2
    result["attempts"][0]["ok"].should == false
    result["attempts"][1]["ok"].should == true
    prompts[1].should.include?("rating")
  end

  it "returns the exhausted envelope after the attempt cap" do
    seen = []
    result = recovery.run_generation_with_recovery(
      base_prompt: "P", catalog: catalog,
      invoke_subagent: ->(_p, _a) { bad_args },
      build_envelope: build_envelope,
      on_attempt: ->(record) { seen << record },
    )

    result["ok"].should == false
    result["attempts"].length.should == recovery::MAX_A2UI_ATTEMPTS
    seen.length.should == recovery::MAX_A2UI_ATTEMPTS

    parsed = JSON.parse(result["envelope"])
    parsed["code"].should == "a2ui_recovery_exhausted"
    parsed["error"].to_s.empty?.should == false
    parsed["attempts"].should.be.kind_of(Array)
  end

  it "honours a maxAttempts override" do
    calls = []
    result = recovery.run_generation_with_recovery(
      base_prompt: "P", catalog: catalog, config: { "maxAttempts" => 2 },
      invoke_subagent: ->(_p, attempt) { calls << attempt; bad_args },
      build_envelope: build_envelope,
    )

    result["ok"].should == false
    calls.length.should == 2
  end

  it "treats a missing tool call as retryable" do
    result = recovery.run_generation_with_recovery(
      base_prompt: "P", catalog: catalog,
      invoke_subagent: ->(_p, attempt) { attempt == 1 ? nil : good_args },
      build_envelope: build_envelope,
    )

    result["ok"].should == true
    result["attempts"].length.should == 2
    result["attempts"][0]["ok"].should == false
  end
end
