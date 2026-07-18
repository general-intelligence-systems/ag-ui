# frozen_string_literal: true

require "bundler/setup"
require "ag_ui"

module AgUi
  module A2ui
    # Semantic validation of A2UI v0.9 component trees — Ruby port of the
    # protocol repo's a2ui_toolkit validate.py (itself a port of the TS
    # a2ui-toolkit), kept behaviorally identical so this middleware and the
    # sibling toolkits agree on what "valid" means.
    #
    # Errors are plain hashes {"code", "path", "message"} — JSON-friendly so
    # they can ride straight into a prompt or event payload.
    #
    #   AgUi::A2ui.validate_components(components: [...], data: {...},
    #                                  catalog: { "components" => {...} })
    #   #=> { "valid" => false, "errors" => [{ "code" => ..., ... }] }
    module Validate
      module_function

      # Structural checks always run. Catalog membership + required-prop
      # checks run only when a catalog is supplied. Absolute binding paths
      # ("/foo") resolve against data; relative template paths ("name")
      # are left alone — they resolve per-item inside repeated templates.
      def validate_components(components:, data: nil, catalog: nil, validate_bindings: true)
        if !components.is_a?(Array) || components.empty?
          {
            "valid" => false,
            "errors" => [{
              "code" => "empty_components",
              "path" => "components",
              "message" => "A2UI components must be a non-empty array",
            }],
          }
        else
          validate_populated(components, data, catalog, validate_bindings)
        end
      end

      def validate_populated(components, data, catalog, validate_bindings)
        errors = []
        ids = collect_ids(components, errors)
        catalog_components = catalog.is_a?(Hash) ? (catalog["components"] || {}) : {}

        components.each_with_index do |comp, i|
          check_identity(comp, i, errors)
          check_catalog(comp, i, catalog, catalog_components, errors)
          check_refs_and_bindings(comp, i, ids, catalog_components, data, validate_bindings, errors)
        end

        find_child_cycles(components, catalog_components).each do |cycle|
          chain = (cycle + [cycle.first]).join(" -> ")
          errors << {
            "code" => "child_cycle",
            "path" => "components[id=#{cycle.first}]",
            "message" => "Child reference cycle detected: #{chain}",
          }
        end

        unless components.any? { |c| c.is_a?(Hash) && c["id"] == "root" }
          errors << {
            "code" => "no_root",
            "path" => "components",
            "message" => "No component has id 'root'",
          }
        end

        { "valid" => errors.empty?, "errors" => errors }
      end

      def collect_ids(components, errors)
        ids = Set.new
        seen = Set.new
        components.each do |comp|
          cid = comp.is_a?(Hash) ? comp["id"] : nil
          if cid.is_a?(String)
            if seen.include?(cid)
              errors << {
                "code" => "duplicate_id",
                "path" => "components[id=#{cid}]",
                "message" => "Duplicate component id '#{cid}'",
              }
            end
            seen << cid
            ids << cid
          end
        end
        ids
      end

      def check_identity(comp, index, errors)
        cid = comp.is_a?(Hash) ? comp["id"] : nil
        ctype = comp.is_a?(Hash) ? comp["component"] : nil

        unless cid.is_a?(String) && !cid.empty?
          errors << {
            "code" => "missing_id",
            "path" => "components[#{index}].id",
            "message" => "Component at index #{index} is missing a string 'id'",
          }
        end
        unless ctype.is_a?(String) && !ctype.empty?
          errors << {
            "code" => "missing_component_type",
            "path" => "components[#{index}].component",
            "message" => "Component at index #{index} is missing a string 'component' type",
          }
        end
      end

      def check_catalog(comp, index, catalog, catalog_components, errors)
        ctype = comp.is_a?(Hash) ? comp["component"] : nil
        if catalog && ctype.is_a?(String)
          schema = catalog_components[ctype]
          if schema.nil?
            errors << {
              "code" => "unknown_component",
              "path" => "components[#{index}].component",
              "message" => "Component type '#{ctype}' is not in the catalog",
            }
          else
            (schema["required"] || []).each do |req|
              unless comp.is_a?(Hash) && comp.key?(req)
                errors << {
                  "code" => "missing_required_prop",
                  "path" => "components[#{index}].#{req}",
                  "message" => "Component '#{ctype}' (index #{index}) is missing required prop '#{req}'",
                }
              end
            end
          end
        end
      end

      def check_refs_and_bindings(comp, index, ids, catalog_components, data, validate_bindings, errors)
        if comp.is_a?(Hash)
          ctype = comp["component"]
          schema = ctype.is_a?(String) ? catalog_components[ctype] : nil

          collect_component_ref_edges(comp, schema).each do |(ref_path, ref)|
            unless ids.include?(ref)
              errors << {
                "code" => "unresolved_child",
                "path" => "components[#{index}].#{ref_path}",
                "message" => "Child reference '#{ref}' does not match any component id",
              }
            end
          end

          if validate_bindings
            collect_absolute_binding_paths(comp, []).each do |path|
              unless absolute_path_resolves?(path, data || {})
                errors << {
                  "code" => "unresolved_binding",
                  "path" => "components[#{index}]",
                  "message" => "Binding path '#{path}' does not resolve in the data model",
                }
              end
            end
          end
        end
      end

      UNRESOLVED = Object.new

      def absolute_path_resolves?(path, data)
        segments = path.split("/").reject(&:empty?)
        resolved = segments.reduce(data) do |cursor, seg|
          case cursor
          when Array
            begin
              idx = Integer(seg, 10)
            rescue ArgumentError
              idx = nil
            end
            if idx.nil? || idx.negative? || idx >= cursor.length
              break UNRESOLVED
            end
            cursor[idx]
          when Hash
            unless cursor.key?(seg)
              break UNRESOLVED
            end
            cursor[seg]
          else
            break UNRESOLVED
          end
        end
        !resolved.equal?(UNRESOLVED)
      end

      # A bare string id, or a {componentId: ...} template — the two child
      # reference shapes.
      def collect_child_refs(children)
        refs = []
        push = ->(v) do
          if v.is_a?(String)
            refs << v
          elsif v.is_a?(Hash) && v["componentId"].is_a?(String)
            refs << v["componentId"]
          end
        end

        if children.is_a?(Array)
          children.each { |v| push.(v) }
        else
          push.(children)
        end
        refs
      end

      # (path_suffix, ref_id) pairs for every child reference a component
      # makes. Implicit `child`/`children` are ALWAYS refs (catalog-free
      # behaviour preserved); other fields only when the catalog schema
      # marks them "format": "componentRef" / "componentRefList" (with
      # array-of-object item schemas honoured per element — finds Tabs
      # tabItems[].child). Unmarked props are data, never refs.
      def collect_component_ref_edges(comp, schema)
        edges = []

        push_single = ->(field, value) do
          collect_child_refs(value).each { |ref| edges << [field, ref] }
        end
        push_list = ->(field, value) do
          if value.is_a?(Array)
            value.each_with_index do |item, k|
              collect_child_refs(item).each { |ref| edges << ["#{field}[#{k}]", ref] }
            end
          else
            collect_child_refs(value).each { |ref| edges << [field, ref] }
          end
        end

        push_single.("child", comp["child"])
        push_list.("children", comp["children"])

        props = schema.is_a?(Hash) ? schema["properties"] : nil
        if props.is_a?(Hash)
          props.each do |field, prop_schema|
            if %w[child children].include?(field) || !prop_schema.is_a?(Hash)
              next
            end

            case prop_schema["format"]
            when "componentRef"
              push_single.(field, comp[field])
            when "componentRefList"
              push_list.(field, comp[field])
            else
              collect_array_item_edges(comp, field, prop_schema, edges)
            end
          end
        end
        edges
      end

      def collect_array_item_edges(comp, field, prop_schema, edges)
        items = prop_schema["items"]
        item_props = items.is_a?(Hash) ? items["properties"] : nil
        arr_val = comp[field]
        if prop_schema["type"] == "array" && item_props.is_a?(Hash) && arr_val.is_a?(Array)
          arr_val.each_with_index do |item, k|
            unless item.is_a?(Hash)
              next
            end

            item_props.each do |sub, sub_schema|
              unless sub_schema.is_a?(Hash)
                next
              end

              case sub_schema["format"]
              when "componentRef"
                collect_child_refs(item[sub]).each { |ref| edges << ["#{field}[#{k}].#{sub}", ref] }
              when "componentRefList"
                sub_val = item[sub]
                if sub_val.is_a?(Array)
                  sub_val.each_with_index do |sv, j|
                    collect_child_refs(sv).each { |ref| edges << ["#{field}[#{k}].#{sub}[#{j}]", ref] }
                  end
                else
                  collect_child_refs(sub_val).each { |ref| edges << ["#{field}[#{k}].#{sub}", ref] }
                end
              end
            end
          end
        end
      end

      def child_adjacency(components, catalog_components)
        adj = {}
        components.each do |comp|
          if comp.is_a?(Hash) && comp["id"].is_a?(String)
            ctype = comp["component"]
            schema = ctype.is_a?(String) ? catalog_components[ctype] : nil
            adj[comp["id"]] = collect_component_ref_edges(comp, schema).map { |(_p, ref)| ref }
          end
        end
        adj
      end

      # Unique child-reference cycles via ITERATIVE DFS (explicit frame
      # stack) — the validator runs on untrusted model output, so a
      # pathologically deep chain must not blow the Ruby stack. Cycles are
      # canonicalised (smallest id leads) so the same loop reached from
      # different entry points collapses to one finding.
      def find_child_cycles(components, catalog_components)
        adj = child_adjacency(components, catalog_components)
        color = {}   # absent = unvisited, 1 = on stack, 2 = done
        cycles = {}

        canonical = ->(nodes) do
          m = (0...nodes.length).min_by { |i| nodes[i] }
          nodes[m..] + nodes[...m]
        end

        adj.each_key do |root|
          if color.key?(root)
            next
          end

          frames = [[root, 0]]
          path = [root]
          color[root] = 1
          until frames.empty?
            node, i = frames.last
            neighbors = adj[node] || []
            if i >= neighbors.length
              color[node] = 2
              frames.pop
              path.pop
              next
            end
            frames.last[1] += 1
            v = neighbors[i]
            case color[v]
            when nil
              color[v] = 1
              path << v
              frames << [v, 0]
            when 1
              cyc = canonical.(path[path.index(v)..])
              cycles[cyc.join(" ")] ||= cyc
            end
          end
        end
        cycles.values
      end

      def collect_absolute_binding_paths(node, acc)
        case node
        when Array
          node.each { |v| collect_absolute_binding_paths(v, acc) }
        when Hash
          p = node["path"]
          if p.is_a?(String) && p.start_with?("/")
            acc << p
          end
          node.each do |k, v|
            unless k == "path"
              collect_absolute_binding_paths(v, acc)
            end
          end
        end
        acc
      end
    end

    # Public entrypoint, mirroring the toolkit's validate_a2ui_components.
    def self.validate_components(...)
      Validate.validate_components(...)
    end
  end
end

__END__

describe "AgUi::A2ui.validate_components" do
  # Fixtures ported verbatim from the toolkit's test_validate.py.
  catalog = {
    "components" => {
      "Row" => { "type" => "object", "required" => ["children"] },
      "HotelCard" => {
        "type" => "object",
        "required" => %w[name location rating pricePerNight],
      },
    },
  }

  valid_components = -> do
    [
      { "id" => "root", "component" => "Row",
        "children" => { "componentId" => "card", "path" => "/items" } },
      { "id" => "card", "component" => "HotelCard",
        "name" => { "path" => "name" }, "location" => { "path" => "location" },
        "rating" => { "path" => "rating" }, "pricePerNight" => { "path" => "pricePerNight" } },
    ]
  end

  valid_data = {
    "items" => [{ "name" => "Ritz", "location" => "NYC", "rating" => 4.8, "pricePerNight" => "$450" }],
  }

  codes = ->(result) { result["errors"].map { |e| e["code"] } }

  it "accepts a well-formed surface" do
    r = AgUi::A2ui.validate_components(components: valid_components.(), data: valid_data, catalog: catalog)
    r["valid"].should == true
    r["errors"].should == []
  end

  it "flags a missing root" do
    comps = valid_components.().map { |c| c["id"] == "root" ? c.merge("id" => "container") : c }
    r = AgUi::A2ui.validate_components(components: comps, data: valid_data, catalog: catalog)
    r["valid"].should == false
    codes.(r).should.include?("no_root")
  end

  it "flags missing id / component type / duplicate ids" do
    codes.(AgUi::A2ui.validate_components(components: [{ "component" => "Row", "children" => [] }]))
      .should.include?("missing_id")
    codes.(AgUi::A2ui.validate_components(components: [{ "id" => "root" }]))
      .should.include?("missing_component_type")

    comps = [
      { "id" => "root", "component" => "Row", "children" => ["x"] },
      { "id" => "x", "component" => "Row", "children" => [] },
      { "id" => "x", "component" => "Row", "children" => [] },
    ]
    codes.(AgUi::A2ui.validate_components(components: comps)).should.include?("duplicate_id")
  end

  it "fails loud on empty or non-array payloads" do
    AgUi::A2ui.validate_components(components: [])["valid"].should == false
    AgUi::A2ui.validate_components(components: nil)["valid"].should == false
  end

  it "flags unknown components and missing required props (catalog only)" do
    mystery = valid_components.().map { |c| c["id"] == "card" ? c.merge("component" => "MysteryCard") : c }
    codes.(AgUi::A2ui.validate_components(components: mystery, data: valid_data, catalog: catalog))
      .should.include?("unknown_component")

    trimmed = valid_components.().map do |c|
      c["id"] == "card" ? c.reject { |k, _| k == "pricePerNight" } : c
    end
    r = AgUi::A2ui.validate_components(components: trimmed, data: valid_data, catalog: catalog)
    r["errors"].any? { |e| e["code"] == "missing_required_prop" && e["message"].include?("pricePerNight") }
      .should == true

    # Structural-only without a catalog.
    r = AgUi::A2ui.validate_components(components: mystery, data: valid_data)
    codes.(r).should.not.include?("unknown_component")
    r["valid"].should == true
  end

  it "flags dangling child references in all three shapes" do
    template = [{ "id" => "root", "component" => "Row",
                  "children" => { "componentId" => "ghost", "path" => "/items" } }]
    r = AgUi::A2ui.validate_components(components: template, data: valid_data, catalog: catalog)
    r["errors"].any? { |e| e["code"] == "unresolved_child" && e["message"].include?("ghost") }.should == true

    array = [{ "id" => "root", "component" => "Row", "children" => ["missing-1"] }]
    codes.(AgUi::A2ui.validate_components(components: array)).should.include?("unresolved_child")

    singular = [{ "id" => "root", "component" => "Card", "child" => "ghost" }]
    r = AgUi::A2ui.validate_components(components: singular)
    r["errors"].any? { |e| e["code"] == "unresolved_child" && e["path"] == "components[0].child" }
      .should == true

    resolved = [
      { "id" => "root", "component" => "Card", "child" => "label" },
      { "id" => "label", "component" => "Text" },
    ]
    codes.(AgUi::A2ui.validate_components(components: resolved)).should.not.include?("unresolved_child")
  end

  it "detects self-referential and multi-component cycles exactly once" do
    selfref = [{ "id" => "avatar", "component" => "Card", "child" => "avatar" }]
    r = AgUi::A2ui.validate_components(components: selfref)
    r["valid"].should == false
    r["errors"].any? { |e| e["code"] == "child_cycle" && e["message"].include?("avatar -> avatar") }
      .should == true

    loop_comps = [
      { "id" => "root", "component" => "Row", "children" => ["a"] },
      { "id" => "a", "component" => "Row", "children" => ["b"] },
      { "id" => "b", "component" => "Row", "children" => ["a"] },
    ]
    r = AgUi::A2ui.validate_components(components: loop_comps)
    r["errors"].count { |e| e["code"] == "child_cycle" }.should == 1
    r["errors"].any? { |e| e["code"] == "child_cycle" && e["message"].include?("a -> b -> a") }
      .should == true

    acyclic = [
      { "id" => "root", "component" => "Row", "children" => %w[a b] },
      { "id" => "a", "component" => "Text" },
      { "id" => "b", "component" => "Text" },
    ]
    codes.(AgUi::A2ui.validate_components(components: acyclic)).should.not.include?("child_cycle")
  end

  it "survives a 5000-deep chain iteratively (no stack overflow)" do
    n = 5000
    comps = [{ "id" => "root", "component" => "Row", "children" => ["n0"] }]
    n.times do |i|
      comps << { "id" => "n#{i}", "component" => "Row",
                 "children" => (i + 1 < n ? ["n#{i + 1}"] : []) }
    end
    codes.(AgUi::A2ui.validate_components(components: comps)).should.not.include?("child_cycle")

    # Same chain closing back to root: exactly one cycle, still no overflow.
    closing = [{ "id" => "root", "component" => "Row", "children" => ["n0"] }]
    n.times do |i|
      closing << { "id" => "n#{i}", "component" => "Row",
                   "children" => [i + 1 < n ? "n#{i + 1}" : "root"] }
    end
    AgUi::A2ui.validate_components(components: closing)["errors"]
      .count { |e| e["code"] == "child_cycle" }.should == 1
  end

  # Catalog-derived ref fields (format: componentRef / componentRefList).
  ref_catalog = {
    "components" => {
      "Modal" => {
        "type" => "object",
        "properties" => {
          "trigger" => { "type" => "string", "format" => "componentRef" },
          "content" => { "type" => "string", "format" => "componentRef" },
          "title" => { "type" => "string" },
        },
      },
      "Tabs" => {
        "type" => "object",
        "properties" => {
          "tabItems" => {
            "type" => "array",
            "items" => { "type" => "object", "properties" => {
              "label" => { "type" => "string" },
              "child" => { "type" => "string", "format" => "componentRef" },
            } },
          },
        },
      },
      "Stack" => { "type" => "object",
                   "properties" => { "items" => { "type" => "array", "format" => "componentRefList" } } },
      "Text" => { "type" => "object" },
    },
  }

  it "derives ref fields from catalog format markers" do
    dangling = [{ "id" => "root", "component" => "Modal",
                  "trigger" => "ghost-btn", "content" => "ghost-body", "title" => "Hi" }]
    r = AgUi::A2ui.validate_components(components: dangling, catalog: ref_catalog)
    r["errors"].any? { |e| e["path"] == "components[0].trigger" && e["message"].include?("ghost-btn") }
      .should == true
    r["errors"].any? { |e| e["path"] == "components[0].content" && e["message"].include?("ghost-body") }
      .should == true

    # Unmarked data strings are never refs.
    ok = [
      { "id" => "root", "component" => "Modal",
        "trigger" => "btn", "content" => "body", "title" => "not-an-id" },
      { "id" => "btn", "component" => "Text" },
      { "id" => "body", "component" => "Text" },
    ]
    codes.(AgUi::A2ui.validate_components(components: ok, catalog: ref_catalog))
      .should.not.include?("unresolved_child")

    # Without a catalog the marked fields are ignored.
    codes.(AgUi::A2ui.validate_components(components: dangling))
      .should.not.include?("unresolved_child")
  end

  it "finds nested tabItems[].child and list-ref per-index paths" do
    tabs = [
      { "id" => "root", "component" => "Tabs",
        "tabItems" => [{ "label" => "A", "child" => "panel-a" },
                       { "label" => "B", "child" => "ghost-panel" }] },
      { "id" => "panel-a", "component" => "Text" },
    ]
    r = AgUi::A2ui.validate_components(components: tabs, catalog: ref_catalog)
    r["errors"].any? { |e| e["path"] == "components[0].tabItems[1].child" }.should == true
    r["errors"].any? { |e| e["path"] == "components[0].tabItems[0].child" }.should == false

    stack = [{ "id" => "root", "component" => "Stack", "items" => %w[x ghost-1] },
             { "id" => "x", "component" => "Text" }]
    r = AgUi::A2ui.validate_components(components: stack, catalog: ref_catalog)
    r["errors"].any? { |e| e["path"] == "components[0].items[1]" && e["message"].include?("ghost-1") }
      .should == true
  end

  it "detects cycles through catalog-marked fields" do
    comps = [
      { "id" => "root", "component" => "Modal", "content" => "b" },
      { "id" => "b", "component" => "Card", "child" => "root" },
    ]
    r = AgUi::A2ui.validate_components(components: comps, catalog: ref_catalog)
    r["errors"].count { |e| e["code"] == "child_cycle" }.should == 1
  end

  it "resolves absolute bindings against data, leaves relative ones alone" do
    r = AgUi::A2ui.validate_components(components: valid_components.(), data: {}, catalog: catalog)
    r["errors"].any? { |e| e["code"] == "unresolved_binding" && e["message"].include?("/items") }
      .should == true

    r = AgUi::A2ui.validate_components(components: valid_components.(), data: valid_data, catalog: catalog)
    codes.(r).should.not.include?("unresolved_binding")

    r = AgUi::A2ui.validate_components(
      components: valid_components.(), data: {}, catalog: catalog, validate_bindings: false,
    )
    codes.(r).should.not.include?("unresolved_binding")
    r["valid"].should == true
  end
end
