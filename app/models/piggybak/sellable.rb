class Piggybak::Sellable < ActiveRecord::Base
  belongs_to :item, :polymorphic => true, :inverse_of => :piggybak_sellable

  validates :sku, presence: true, uniqueness: true
  validates :description, presence: true
  validates :price, presence: true
  validates :item_type, presence: true
  validates_numericality_of :quantity, :only_integer => true, :greater_than_or_equal_to => 0

  has_many :line_items, :as => :reference, :inverse_of => :reference

  def admin_label
    self.description
  end

  def update_inventory(purchased)
    new_quantity = self.quantity + purchased
    if new_quantity < 0
      new_quantity = 0
      self.vendor_specific_item.update(backordered: true)
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
  
end
