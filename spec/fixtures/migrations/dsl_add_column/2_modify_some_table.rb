# frozen_string_literal: true

class ModifySomeTable < ActiveRecord::Migration[6.0]
  def up
    add_column :some, :new_column, :big_integer
  end
end

