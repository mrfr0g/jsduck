require "jsduck/serializer"
require "jsduck/evaluator"

module JsDuck

  # Analyzes the AST produced by EsprimaParser.
  class Ast
    def initialize
      @serializer = JsDuck::Serializer.new
      @evaluator = JsDuck::Evaluator.new
    end

    # Given parsed code, returns the tagname for documentation item.
    #
    # @param ast :code from Result of EsprimaParser
    # @returns One of: :class, :method, :property
    #
    def detect(ast)
      ast = ast || {}

      exp = expression?(ast) ? ast["expression"] : nil
      var = var?(ast) ? ast["declarations"][0] : nil

      # Ext.define("Class", {})
      if exp && ext_define?(exp)
        make_class(to_value(exp["arguments"][0]), exp)

      # foo = Ext.extend("Parent", {})
      elsif exp && assignment?(exp) && ext_extend?(exp["right"])
        make_class(to_s(exp["left"]), exp["right"])

      # Foo = ...
      elsif exp && assignment?(exp) && class_name?(to_s(exp["left"]))
        make_class(to_s(exp["left"]))

      # var foo = Ext.extend("Parent", {})
      elsif var && var["init"] && ext_extend?(var["init"])
        make_class(to_s(var["id"]), var["init"])

      # var Foo = ...
      elsif var && class_name?(to_s(var["id"]))
        make_class(to_s(var["id"]))

      # function Foo() {}
      elsif function?(ast) && class_name?(to_s(ast["id"]))
        make_class(to_s(ast["id"]))

      # function foo() {}
      elsif function?(ast)
        make_method(to_s(ast["id"]), ast)

      # foo = function() {}
      elsif exp && assignment?(exp) && function?(exp["right"])
        make_method(to_s(exp["left"]), exp["right"])

      # var foo = function() {}
      elsif var && var["init"] && function?(var["init"])
        make_method(to_s(var["id"]), var["init"])

      # (function() {})
      elsif exp && function?(exp)
        make_method(exp["id"] ? to_s(exp["id"]) : "", exp)

      # foo: function() {}
      elsif property?(ast) && function?(ast["value"])
        make_method(key_value(ast["key"]), ast["value"])

      # foo = ...
      elsif exp && assignment?(exp)
        make_property(to_s(exp["left"]), exp["right"])

      # var foo = ...
      elsif var
        make_property(to_s(var["id"]), var["init"])

      # foo: ...
      elsif property?(ast)
        make_property(key_value(ast["key"]), ast["value"])

      # foo;
      elsif exp && ident?(exp)
        make_property(to_s(exp))

      # "foo"  (inside some expression)
      elsif string?(ast)
        make_property(to_value(ast))

      # "foo";  (as a statement of it's own)
      elsif exp && string?(exp)
        make_property(to_value(exp))

      else
        make_property()
      end
    end

    private

    def expression?(ast)
      ast["type"] == "ExpressionStatement"
    end

    def call?(ast)
      ast["type"] == "CallExpression"
    end

    def assignment?(ast)
      ast["type"] == "AssignmentExpression"
    end

    def ext_define?(ast)
      call?(ast) && ["Ext.define", "Ext.ClassManager.create"].include?(to_s(ast["callee"]))
    end

    def ext_extend?(ast)
      call?(ast) && to_s(ast["callee"]) == "Ext.extend"
    end

    def function?(ast)
      ast["type"] == "FunctionDeclaration" || ast["type"] == "FunctionExpression" || empty_fn?(ast)
    end

    def empty_fn?(ast)
      ast["type"] == "MemberExpression" && to_s(ast) == "Ext.emptyFn"
    end

    def var?(ast)
      ast["type"] == "VariableDeclaration"
    end

    def property?(ast)
      ast["type"] == "Property"
    end

    def ident?(ast)
      ast["type"] == "Identifier"
    end

    def string?(ast)
      ast["type"] == "Literal" && ast["value"].is_a?(String)
    end

    # Class name begins with upcase char
    def class_name?(name)
      return name.split(/\./).last =~ /\A[A-Z]/
    end

    def make_class(name, ast=nil)
      cls = {
        :tagname => :class,
        :name => name,
      }

      # apply information from Ext.extend or Ext.define
      if ast
        if ext_extend?(ast)
          cls[:extends] = to_s(ast["arguments"][0])

        elsif ext_define?(ast)
          cfg = object_expression_to_hash(ast["arguments"][1])

          cls[:extends] = make_extends(cfg["extend"]) || "Ext.Base"
          cls[:requires] = make_string_list(cfg["requires"])
          cls[:uses] = make_string_list(cfg["uses"])
          cls[:alternateClassNames] = make_string_list(cfg["alternateClassName"])
          cls[:mixins] = make_mixins(cfg["mixins"])
          cls[:singleton] = make_singleton(cfg["singleton"])
          cls[:aliases] = make_string_list(cfg["alias"])
          cls[:aliases] += make_string_list(cfg["xtype"]).map {|xtype| "widget."+xtype }
          cls[:members] = {}
          cls[:members][:cfg] = make_config(cfg["config"])
        end
      end

      return cls
    end

    def make_extends(cfg_value)
      return nil unless cfg_value

      parent = to_value(cfg_value)

      return parent.is_a?(String) ? parent : nil
    end

    def make_string_list(cfg_value)
      return [] unless cfg_value

      classes = Array(to_value(cfg_value))

      return classes.all? {|c| c.is_a? String } ? classes : []
    end

    def make_mixins(cfg_value)
      return [] unless cfg_value

      v = to_value(cfg_value)
      classes = v.is_a?(Hash) ? v.values : Array(v)

      return classes.all? {|c| c.is_a? String } ? classes : []
    end

    def make_singleton(cfg_value)
      cfg_value && to_value(cfg_value) == true
    end

    def make_config(ast)
      return nil unless ast && ast["type"] == "ObjectExpression"

      configs = []
      object_expression_to_hash(ast).each_pair do |key, value|
        configs << make_property(key, value, :cfg)
      end
      configs
    end

    def make_method(name, ast=nil)
      return {
        :tagname => :method,
        :name => name,
        :params => make_params(ast)
      }
    end

    def make_params(ast)
      if ast && !empty_fn?(ast)
        ast["params"].map {|p| {:name => to_s(p)} }
      else
        []
      end
    end

    def make_property(name=nil, ast=nil, tagname=:property)
      return {
        :tagname => tagname,
        :name => name,
        :type => make_value_type(ast),
        :default => make_default(ast),
      }
    end

    def make_default(ast)
      ast && to_value(ast) ? to_s(ast) : nil
    end

    def make_value_type(ast)
      if ast
        v = to_value(ast)
        if v.is_a?(String)
          "String"
        elsif v.is_a?(Numeric)
          "Number"
        elsif v.is_a?(TrueClass) || v.is_a?(FalseClass)
          "Boolean"
        elsif v.is_a?(Array)
          "Array"
        elsif v.is_a?(Hash)
          "Object"
        elsif v == :regexp
          "RegExp"
        else
          nil
        end
      else
        nil
      end
    end

    # -- various helper methods --

    # Turns ObjectExpression into Ruby Hash for easy lookup.  The keys
    # are turned into strings, but values are left as is for further
    # processing.
    def object_expression_to_hash(ast)
      h = {}
      if ast && ast["type"] == "ObjectExpression"
        ast["properties"].each do |p|
          h[key_value(p["key"])] = p["value"]
        end
      end
      return h
    end

    # Converts object expression property key to string value
    def key_value(key)
      @evaluator.key_value(key)
    end

    # Fully serializes the node
    def to_s(ast)
      @serializer.to_s(ast)
    end

    # Converts AST node into a value.
    def to_value(ast)
      begin
        @evaluator.to_value(ast)
      rescue
        nil
      end
    end
  end

end
