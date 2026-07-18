# frozen_string_literal: true

require "json"
require "json_schemer"
require "rack"
require "stringio"

module AgUi
end

require "ag_ui/version"
require "ag_ui/protocol/json_schema"
require "ag_ui/protocol/json_schema/definition"
require "ag_ui/protocol/json_schema/validation_error"
require "ag_ui/server/sse/event_encoder"
require "ag_ui/server/sse/stream"
require "ag_ui/server/middleware/sse_stream"
require "ag_ui/run_input"
require "ag_ui/server"

require "brute"
require "ag_ui/messages"
require "ag_ui/event_bridge"
require "ag_ui/middleware/system_prompt"
require "ag_ui/middleware/tool_router"
require "ag_ui/a2ui/catalog"
require "ag_ui/middleware/a2ui"
require "ag_ui/run_loop"
