class Mention < ApplicationRecord
  belongs_to :message
  belongs_to :alias, class_name: 'Alias'
end
