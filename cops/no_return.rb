# frozen_string_literal: true

# Bans the `return` keyword. A method's last expression is its return value;
# early exits must be expressed through `if` / `unless` / `case` structure,
# not by short-circuiting out of the middle of a block.
module RuboCop
  module Cop
    module Local
      class NoReturn < Base
        MSG = "Do not use `return`; let the method's last expression be the return value."

        def on_return(node)
          add_offense(node)
        end
      end
    end
  end
end
