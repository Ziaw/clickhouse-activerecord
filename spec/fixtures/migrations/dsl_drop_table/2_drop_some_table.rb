# frozen_string_literal: true

class DropSomeTable < ActiveRecord::Migration[6.0]
  def up
    drop_table :some
  end
end

