class AddPostAddressToMailingLists < ActiveRecord::Migration[8.0]
  def change
    add_column :mailing_lists, :post_address, :string
  end
end
