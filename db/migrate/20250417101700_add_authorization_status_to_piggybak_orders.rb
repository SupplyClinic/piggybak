class AddAuthorizationStatusToPiggybakOrders < ActiveRecord::Migration[7.0]
  def up
    add_column :piggybak_orders, :authorization_status, :integer, default: 0

    Order.where(authorized: true).update_all(authorization_status: 2)

    Order.joins(:line_items).where(line_items: { line_item_type: 'rejected_sellable' }).update_all(authorization_status: 1)

    remove_column :piggybak_orders, :authorized
  end

  def down
    add_column :piggybak_orders, :authorized, :boolean, default: false

    Order.where(authorization_status: 'fully_authorized').update_all(authorized: true)

    remove_column :piggybak_orders, :authorization_status
  end
end
