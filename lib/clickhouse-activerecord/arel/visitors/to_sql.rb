require 'arel/visitors/to_sql'

module ClickhouseActiverecord
  module Arel
    module Visitors
      class ToSql < ::Arel::Visitors::ToSql
        def aggregate(name, o, collector)
          # replacing function name for materialized view
          if o.expressions.first && o.expressions.first != '*' && !o.expressions.first.is_a?(String) && o.expressions.first.relation && o.expressions.first.relation.engine && o.expressions.first.relation.engine.is_view
            super("#{name.downcase}Merge", o, collector)
          else
            super
          end
        end

        def preparable
          false
        end

        private

        def visit_Arel_Nodes_Offset(o, collector)
          parts = collector.instance_variable_get(:@parts)
          clause, limit, _ = parts.last(3)
          return if clause != 'LIMIT '
          collector.instance_variable_get(:@parts)[-2] = o.expr
          collector.instance_variable_get(:@parts)[-1] = ','
          visit limit.to_i, collector
        end
      end
    end
  end
end
