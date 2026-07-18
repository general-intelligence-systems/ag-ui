# frozen_string_literal: true

# Bans the modifier `if` / `unless` (trailing conditional) form:
#
#   return true if task.state_task_completed?     # NO
#
#   if task.state_task_completed?                 # YES
#     return true
#   end
#
# Modifier form hides the guard and mixes control flow with the statement it
# guards; the block form makes both the condition and the branch obvious.
module RuboCop
  module Cop
    module Local
      class NoModifierIf < Base
        MSG = "Do not use modifier `%<keyword>s`; use the full `%<keyword>s ... end` block form."

        def on_if(node)
          if node.modifier_form?
            add_offense(node, message: format(MSG, keyword: node.keyword))
          end
        end
      end
    end
  end
end
