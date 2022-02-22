class Piggybak::Sellable < ActiveRecord::Base
  belongs_to :item, :polymorphic => true, :inverse_of => :piggybak_sellable

  validates :sku, presence: true, uniqueness: true
  validates :description, presence: true
  validates :price, presence: true
  validates :item_type, presence: true
  validates_numericality_of :quantity, :only_integer => true, :greater_than_or_equal_to => 0

  has_many :line_items, :as => :reference, :inverse_of => :reference

  belongs_to :vsi, -> { joins(:piggybak_sellable).where(piggybak_sellables: {item_type: 'VendorSpecificItem'}) }, foreign_key: 'item_id', class_name: 'VendorSpecificItem'
  belongs_to :user, :foreign_key => "quantity_last_updated_by"
  before_destroy :prevent_destroy
  before_save :set_naked_sku
  before_save :set_unlimited_inventory

  def prevent_destroy
    # Once a sellable has been purchased, it cannot be destroyed.
    if Piggybak::LineItem.where(sellable_id: self.id).any?
      false
    else
      true
    end
  end

  def vsi
    return unless item_type == "VendorSpecificItem"
    super
  end

  def vendor_specific_item
    if self.item_type == "VendorSpecificItem" 
      return self.item
    elsif self.item_type == "PiggybakVariants::Variant"
      variant = self.item
      if variant.item_type == "VendorSpecificItem"
        return variant.item
      else
        return nil
      end    
    end
  end

  def situational_price(user)
    if user && user.has_special_pricing_for(self.vsi)
      user.special_pricing_for(self.vsi)
    else
      self.price
    end
  end

  def stock_level_last_updated
    if self.quantity_last_updated_at == nil
      return "UNKNOWN"
    else
      return self.quantity_last_updated_at.strftime("%Y-%m-%d")
    end
  end

  def set_naked_sku
    if self.sku
      post_vendor_tag_index = self.sku.index("]")+1
      self.naked_sku = self.sku[post_vendor_tag_index..-1]
    else
      self.naked_sky = ""
    end
  end

  def set_unlimited_inventory
    vsi = self.vsi
    if vsi && (vsi.visibility_when_qty_0 == 'out of stock' || vsi.visibility_when_qty_0 == 'hidden')
      self.unlimited_inventory = false
    else
      self.unlimited_inventory = true
    end
    true
  end

  def admin_label
    self.description
  end

  def update_inventory(purchased)
    new_quantity = self.quantity + purchased
    if new_quantity < 0
      new_quantity = 0
    end
    if new_quantity == 0
      self.vendor_specific_item.set_backorder(new_quantity)
    end
    self.update_attribute(:quantity, new_quantity)
  end

  def vendor_specific_item
    if self.item_type == "VendorSpecificItem" 
      return self.item
    elsif self.item_type == "PiggybakVariants::Variant"
      variant = self.item
      if variant.item_type == "VendorSpecificItem"
        return variant.item
      else
        return nil
      end    
    end
  end

  def set_vsi_to_backordered_async
    vsi = self.item
    vsi.reload
    if vsi.is_excluded_from_slu == true && ["backordered", "out of stock", "special order"].include?(vsi.visibility_when_not_on_slu)
      vsi.backordered = true
      vsi.save
    elsif self.quantity == 0
      if ["backordered", "out of stock", "special order"].include?(vsi.visibility_when_qty_0)
        vsi.backordered = true
        vsi.save
      end
    end
  end

  
end
