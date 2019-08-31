require 'arel/visitors/to_sql'

module ClickhouseActiverecord
  module Arel
    module Visitors
      class ToSql < ::Arel::Visitors::ToSql
        WHERE = ' PREWHERE '

        def aggregate(name, o, collector)
          # replacing function name for materialized view
          if o.expressions.first && o.expressions.first != '*' && !o.expressions.first.is_a?(String) && o.expressions.first.relation && o.expressions.first.relation.engine && o.expressions.first.relation.engine.is_view
            super("#{name.downcase}Merge", o, collector)
          else
            super
          end
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

        def visit_Arel_Nodes_SelectCore o, collector
          collector << "SELECT"

          collector = maybe_visit o.top, collector

          collector = maybe_visit o.set_quantifier, collector

          unless o.projections.empty?
            collector << SPACE
            len = o.projections.length - 1
            o.projections.each_with_index do |x, i|
              collector = visit(x, collector)
              collector << COMMA unless len == i
            end
          end

          if o.source && !o.source.empty?
            collector << " FROM "
            collector = visit o.source, collector
          end

          unless o.wheres.empty?
            collector << self.class::WHERE
            len = o.wheres.length - 1
            o.wheres.each_with_index do |x, i|
              collector = visit(x, collector)
              collector << AND unless len == i
            end
          end

          unless o.groups.empty?
            collector << GROUP_BY
            len = o.groups.length - 1
            o.groups.each_with_index do |x, i|
              collector = visit(x, collector)
              collector << COMMA unless len == i
            end
          end

          collector = maybe_visit o.having, collector

          unless o.windows.empty?
            collector << WINDOW
            len = o.windows.length - 1
            o.windows.each_with_index do |x, i|
              collector = visit(x, collector)
              collector << COMMA unless len == i
            end
          end

          collector
        end
      end
    end
  end
end
