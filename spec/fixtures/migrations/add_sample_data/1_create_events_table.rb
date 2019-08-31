# frozen_string_literal: true

class CreateEventsTable < ActiveRecord::Migration[6.0]
  def up
    create_table :events, options: 'MergeTree(date, (date, event_name), 8192)' do |t|
      t.string :event_name, null: false
      t.date :date, null: false
      t.datetime :datetime, null: false
      t.boolean :boolean, null: false
    end
  end
end

