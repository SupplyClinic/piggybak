module Piggybak
  class Order < ActiveRecord::Base
    has_many :line_items, :inverse_of => :order
    has_many :order_notes, :inverse_of => :order

    belongs_to :billing_address, :class_name => "Piggybak::Address"
    belongs_to :shipping_address, :class_name => "Piggybak::Address"
    belongs_to :user

    has_many :vendor_orders, foreign_key: "piggybak_order_id"
    has_many :vendors, through: :vendor_orders
    has_many :ledger_line_items, as: :ledgerable, class_name: "Ledger", foreign_key: "ledgerable_id", dependent: :destroy

    belongs_to :order_digest 
    belongs_to :supervisor, class_name: "User"

  
    accepts_nested_attributes_for :billing_address, :allow_destroy => true
    accepts_nested_attributes_for :shipping_address, :allow_destroy => true
    accepts_nested_attributes_for :line_items, :allow_destroy => true
    accepts_nested_attributes_for :order_notes

    attr_accessor :recorded_changes, :recorded_changer,
                  :was_new_record, :disable_order_notes 

    validates :status, presence: true
    validates :email, presence: true
    validates :phone, presence: true
    validates :total, presence: true
    validates :total_due, presence: true
    validates :created_at, presence: true
    validates :ip_address, presence: true
    validates :user_agent, presence: true
    validate :customer_appropriately_licensed, on: :create
    validate :must_have_at_least_one_item, on: :create

    after_initialize :initialize_defaults
    validate :number_payments
    before_save :postprocess_order, :update_status, :set_new_record
    after_save :record_order_note
    after_commit :post_creation_tasks, on: :create
    after_commit :create_ledger_line_item
    before_destroy :destroy_all_children

    def self.calculate_savings_from_line_items(line_items)
      calc_savings = BigDecimal.new("0")
      line_items.each do |line_item|
        qty = line_item.quantity
        price = line_item.price
        unit_price = line_item.unit_price
        msrp = line_item.sellable.vendor_specific_item.item.msrp
        if msrp && (msrp > unit_price)
          sellable_savings = (msrp * qty) - price
          calc_savings += sellable_savings
        end
      end
      calc_savings
    end

    def calculate_savings
      calc_savings = Piggybak::Order.calculate_savings_from_line_items(line_items.sellables)
      self.update_column(:savings, calc_savings)
      calc_savings
    end

    def deliver_order_confirmation
      # moved
    end

    def post_creation_tasks
      if self.request && (self.user.enterprise_payment_method == "credit-card")
        finalize_order
      elsif self.request
        # possibly something else
      else
        finalize_order
      end
    end

    def finalize_order
      if self.capture_charge
        self.calculate_savings
        self.set_tax_info
        self.vendor_orders.each do |vendor_order|
          vendor_order.delay.post_creation_tasks
          Track.suborder_received(vendor_order)
        end
        Track.order_completed(self)
        self.update_column(:confirmation_sent,true)
        self.create_ambassador_referral_association

        # more housekeeping
        Datum.delay.process(self)
        OrderDatum.delay.process(self)
        self.reload
        unless self.no_notification
          Piggybak::Notifier.delay.order_notification(self)
        end
        Sunspot.index! self

        if self.user
          self.user.delay.post_order_tasks(self.subtotal)
        end
      end
    end

    def coupon_use
      self.line_items.find_by(line_item_type: "coupon_application")
    end
 
    def capture_charge
      if !self.has_stripe_charge
        if !self.captured
          self.update_column(:captured,true)
        end
      else
        charge = get_stripe_charge
        if !charge.captured
          begin
            charge.capture
            self.update_column(:captured,true)
          rescue Exception => e
            error_log = ["Order ##{id} failed to capture charge.",
                          "Error: #{e.message}"]
            AdminMailer.logs_email(promo_logs, "dan@supplyclinic.com").deliver
            return false
          end
        elsif !self.captured
          self.update_column(:captured,true)
        end
      end
      return true
    end

    def is_first_order
      self.id == ( self.user.piggybak_orders.first.id )
    end

    def set_carousel_tracking(cookie)
      cookie_tracking = cookie.split(",")
      confirmed_tracking = []
      item_ids = self.line_items.sellables.map{|li| li.sellable.vendor_specific_item.item.id}
      cookie_tracking.each do |tracking_string|
        if tracking_string =~ /\A[PF]\d+\z/
          tracking_item_id = tracking_string[1..-1].to_i
          if item_ids.include? tracking_item_id
            confirmed_tracking << tracking_string
          end
        end
      end
      confirmed_tracking_string = (confirmed_tracking.class == Array) ? confirmed_tracking.join(',') : ''
      self.update(carousel_tracking: confirmed_tracking_string)
    end

    def set_tax_info
      digest = OrderDigest.find(self.order_digest_id)
      tax_per_vendor = digest.tax
      if tax_per_vendor != nil
        if tax_per_vendor.has_key? "details"
          self.update_column(:tax_details, tax_per_vendor["details"])
          if tax_per_vendor["details"].has_key? "supply_clinic_tax"
            self.update_column(:sc_tax, BigDecimal.new(tax_per_vendor["details"]["supply_clinic_tax"]))
          end
        end
      end
    end

    def create_vendor_orders
      if !self.vendor_orders.any?
        items_by_vendor_id = VendorOrder.items_by_vendor_id(self)
        digest = OrderDigest.find(self.order_digest_id)
        tax_per_vendor = digest.tax

        items_by_vendor_id.each do |vendor_id, items|
          # Building Vendor Order
          vendor = Vendor.find(vendor_id)
          vendor_order = vendor.vendor_orders.build(piggybak_order: self)
          if tax_per_vendor != nil
            if tax_per_vendor.has_key? "details"
              vendor_tax_details = tax_per_vendor["details"]["#{vendor_id}"]
              if vendor_tax_details["handled_by_supply_clinic"] || (vendor_tax_details["handled_by_supply_clinic"] == "true")
                vendor_tax = 0
                sc_handles_tax = true
              else
                vendor_tax = BigDecimal.new(vendor_tax_details["subtotal"])
                sc_handles_tax = false
              end
              vendor_order.tax = vendor_tax
              vendor_order.sc_handles_tax = sc_handles_tax
              vendor_order.tax_details = vendor_tax_details
              vendor_order.set_tax_state
              if vendor_tax > 0
                vendor_tax_details["items"].each do |item_tax_info|
                  if item_tax_info["sellable_id"] && !item_tax_info["sellable_id"].blank?
                    sellable_id = item_tax_info["sellable_id"].to_i
                    line_item = self.line_items.find_by(sellable_id: sellable_id)
                    if line_item
                      line_item.update(unit_tax: BigDecimal.new(item_tax_info["unit_tax"]))
                    end
                  end
                end
              end
            else
              vendor_order_tax = tax_per_vendor["#{vendor_id}"]
              vendor_order_tax = BigDecimal("#{vendor_order_tax}") / BigDecimal.new("1.029")
              vendor_order_tax = vendor_order_tax.to_f.round(2)
              vendor_order.tax = vendor_order_tax
            end
          end
          if vendor_order.save
            puts "Order for #{vendor.name} saved."
          else
            throw "Order for #{vendor.name} could not be saved! ERROR: #{vendor_order.errors.full_messages}"
          end
        end
      end
    end

    def any_shipment_created?
      VendorOrder.where(piggybak_order_id: self.id).each do |vendor_order|
        if vendor_order.partially_filled?
          return true
        end
      end
      return false
    end

    def delivered?
      VendorOrder.where(piggybak_order_id: self.id).each do |vendor_order|
        if vendor_order.delivered? == false
          return false
        end
      end
      return true
    end

    #returns true if all non-backordered items have been delivered
    def non_backorder_delivered?
      VendorOrder.where(piggybak_order_id: self.id).each do |vendor_order|
        if vendor_order.delivered? == false
          #check if any of the vendor order's items is on backorder
          items_backorder_status = vendor_order.items.map {|item| item.ordered_on_backorder}
          unless items_backorder_status.include? true
            return false
          end
        end
      end
      return true
    end

    def delivered_at
      # returns delivered_at of latest vendor_order IF all vendor_orders are made and delivered
      lastDate = DateTime.new(2015,1,1)
      vendor_orders = VendorOrder.where(piggybak_order_id: self.id)
      vendor_orders.each do |vendor_order|
        if vendor_order.delivered_at == nil
          return nil
        elsif lastDate < vendor_order.delivered_at
          lastDate = vendor_order.delivered_at
        end
      end
      return lastDate
    end

    # returns delivered_at of latest vendor_order IF all vendor_orders without backordered items are made and delivered
    def non_backorder_delivered_at
      # returns delivered_at of latest vendor_order IF all vendor_orders are made and delivered
      lastDate = DateTime.new(2015,1,1)
      vendor_orders = VendorOrder.where(piggybak_order_id: self.id)
      vendor_orders.each do |vendor_order|
        if vendor_order.delivered_at == nil && !((vendor_order.items.map {|item| item.ordered_on_backorder}).include? true)
          return nil
        elsif (lastDate < vendor_order.delivered_at) && !((vendor_order.items.map {|item| item.ordered_on_backorder}).include? true)
          lastDate = vendor_order.delivered_at
        end
      end
      return lastDate
    end

    def customer_appropriately_licensed
      line_items.each do |line_item|
        if line_item.line_item_type == "sellable"
          vsi = line_item.sellable.vendor_specific_item
          if vsi.purchasable?(self.user, self.shipping_address) == false
            errors[:base] << "You can't purchase the following item due to licensing restrictions: #{vsi.item.name}"
          else
            item = vsi.item
            if item.promo_item_purchasable?(line_item, self) == false
              errors[:base] << item.promo_item_error_message
            end
          end
        end
      end
    end

    def must_have_at_least_one_item
      if line_items.sellables.size < 1
        errors[:base] << "An error occured processing this order. It's possible that a duplicate order was attempted"
      end
    end

    def can_return?
      can_return = false
      vendor_orders = VendorOrder.where(piggybak_order_id: self.id)
      vendor_orders.each do |vo|
        if (vo.can_return? == true) || ((vo.return != nil) && (vo.return.returned == false))
          can_return = true
          break
        end
      end
      return can_return
    end

    def can_cancel?
      can_cancel = true
      vendor_orders = VendorOrder.where(piggybak_order_id: self.id)
      vendor_orders.each do |vendor_order|
        unless vendor_order.can_cancel?
          can_cancel = false
        end
      end
      can_cancel
    end

    def cancel(message, notify_customer=true)
      if self.can_cancel?
        vendor_orders = VendorOrder.where(piggybak_order_id: self.id)
        vendor_orders.each do |vendor_order|
          vendor_order.cancel(message)
        end
        self.update(canceled: true)
        if notify_customer
          CustomerMailer.delay.canceled_notification(self, message)
        end
        true
      else
        false
      end
    end

    def stripe_charge_id
      self.line_items.where(line_item_type: "payment").last.payment.transaction_id
    end

    def has_stripe_charge
      self.stripe_charge_id[0..2] == "ch_"
    end

    def get_stripe_charge
      begin
        charge = Stripe::Charge.retrieve(self.stripe_charge_id)
      rescue Exception => e
        unless e.message.include? "a similar object exists in live mode"
          throw e
        end
        # Test charge
        charge = Stripe::Charge.retrieve("ch_1BDhRo4bUbbiZuyOInzUjL0k")
      end
      charge
    end

    def last4
      if !self.has_stripe_charge
        return "0000"
      else
        return self.get_stripe_charge[:source][:last4]
      end
    end

    def card_brand
      if !self.has_stripe_charge
        return "none"
      else
        return self.get_stripe_charge[:source][:brand]
      end
    end

    def stripe_charge_url
      "https://dashboard.stripe.com/payments/#{self.stripe_charge_id}"
    end

    def destination
      address = self.shipping_address

      destination = {}
      destination[:name]     = "Supply Clinic Customer"
      destination[:address1] = address.address1
      destination[:address2] = address.address2
      destination[:business_name] = address.business_name
      destination[:city]     = address.city
      destination[:state]    = address.state ? address.state.name : address.state_id
      destination[:zip]      = address.zip
      destination[:country]  = "US"
      o_destination = Omniship::Address.new(destination)
    end

    def create_ledger_line_item
      if ledger_line_items.none? && self.line_items.where(line_item_type: "payment").any?
        if self.line_items.find_by(line_item_type: "payment").payment.transaction_id == "credit"
          if ledger_line_items.none? || (self.canceled == true && ledger_line_items.find_by(transaction_type: "cancelation" ).nil?)
            if self.canceled == true
              Ledger.create(ledgerable_id: self.id, ledgerable_type: self.class.name, user_id: self.user_id, transaction_time: DateTime.now, transaction_type: 'cancelation')
            else
              Ledger.create(ledgerable_id: self.id, ledgerable_type: self.class.name, user_id: self.user_id, transaction_time: self.created_at)
            end
          end
          true
        else 
          false
        end
      else
        false
      end
    end

    def ledger_location
      self.user.business_name
    end

    def ledger_event
      "Order"
    end

    def ledger_event_type
      "Credit"
    end

    def ledger_event_code
      "SC0#{self.id}"
    end

    def ledger_subtotal
      self.subtotal
    end

    def ledger_shipping
      self.shipment_charge
    end

    def ledger_tax
      self.tax_charge
    end

    def ledger_total_amount
      self.subtotal + self.shipment_charge + self.tax_charge
    end

    def processing_fee
      self.total * BigDecimal.new("0.029")
    end

    def total_with_processing_fee(total)
      new_total = total / BigDecimal.new("0.971")
    end

    def hidden?
      line_items = self.line_items.sellables
      vendor_orders = VendorOrder.where(piggybak_order_id: self.id)
      line_items.each do |line_item|
        if !line_item.sellable.item.hidden?
          return false
        end
      end
      return true
    end

    def num_hidden
      num_hidden = 0;
      line_items = self.line_items.sellables
      vendor_orders = VendorOrder.where(piggybak_order_id: self.id)
      line_items.each do |line_item|
        if line_item.sellable.item.hidden?
          num_hidden = num_hidden + 1
        end
      end
      num_hidden
    end

    def destroy_all_children
      VendorOrder.where(piggybak_order_id: self.id).destroy_all
      self.billing_address.destroy
      self.shipping_address.destroy
      self.order_notes.destroy_all
    end


    def initialize_defaults
      self.recorded_changes ||= []

      self.billing_address ||= Piggybak::Address.new
      self.shipping_address ||= Piggybak::Address.new
      self.shipping_address.is_shipping = true

      self.ip_address ||= 'admin'
      self.user_agent ||= 'admin'

      self.created_at ||= Time.now
      self.status ||= "new"
      self.total ||= 0
      self.total_due ||= 0
      self.disable_order_notes = false
    end

    def number_payments

      new_payments = self.line_items.payments.select { |li| li.new_record? }
      if new_payments.size > 1
        self.errors.add(:base, "Only one payment may be created at a time.")
        new_payments.each do |li|
          li.errors.add(:line_item_type, "Only one payment may be created at a time.")
        end
      end
    end

    def initialize_user(user)
      if user
        self.user = user
        self.email = user.email 
      end
    end

    def postprocess_order
      postprocess_order_actions
    end

    def postprocess_order_actions
      # Mark line items for destruction if quantity == 0
      self.line_items.each do |line_item|
        if line_item.quantity == 0
          line_item.mark_for_destruction
        end
      end

      # Recalculate and create line item for tax
      # If a tax line item already exists, reset price
      # If a tax line item doesn't, create
      # If tax is 0, destroy tax line item
      tax = Piggybak::TaxMethod.calculate_tax(self)
      tax_line_item = self.line_items.taxes
      if tax > 0
        if tax_line_item.any?
          tax_line_item.first.price = tax
        else
          self.line_items << Piggybak::LineItem.new({ :line_item_type => "tax", :description => "Tax Charge", :price => tax })
        end
      elsif tax_line_item.any?
        tax_line_item.first.mark_for_destruction
      end

      # Postprocess everything but payments first
      self.line_items.each do |line_item|
        next if line_item.line_item_type == "payment"
        method = "postprocess_#{line_item.line_item_type}"
        if line_item.respond_to?(method)
          if !line_item.send(method)
            return false
          end
        end
      end

      # Recalculating total and total due, in case post process changed totals
      self.total_due = 0
      self.total = 0
      self.line_items.each do |line_item|
        if !line_item._destroy && line_item.line_item_type != "coupon_application"
          self.total_due += line_item.price
          if line_item.line_item_type != "payment"
            self.total += line_item.price
          end
        end
      end
      if self.total_due > 0 && self.total > 0
        self.line_items.each do |line_item|
          if !line_item._destroy && line_item.line_item_type == "coupon_application"
            self.total_due += line_item.price
            if line_item.line_item_type != "payment"
              self.total += line_item.price
            end
          end
        end
        if self.total_due < 0
          self.total_due = 0;
        end
        if self.total < 0
          self.total = 0;
        end
      end

      # Add processing fee
      # self.total = self.total_with_processing_fee(self.total)
      # self.total_due = self.total_with_processing_fee(self.total_due)

      # Postprocess payment last
      self.line_items.payments.each do |line_item|
        method = "postprocess_payment"
        if line_item.respond_to?("postprocess_payment")
          if !line_item.postprocess_payment
            line_item.errors.each do |error_name, error_value|
              self.errors.add error_name, error_value
            end
            throw :abort
          end
        end
      end

      true
    end

    def record_order_note
      if self.saved_changes? && !self.was_new_record
        self.recorded_changes << self.formatted_changes
      end

      if self.recorded_changes.any? && !self.disable_order_notes
        OrderNote.create(:order_id => self.id, :note => self.recorded_changes.join("<br />"), :user_id => self.recorded_changer.to_i)
      end
    end

    def create_payment_shipment
      shipment_line_item = self.line_items.detect { |li| li.line_item_type == "shipment" }

      if shipment_line_item.nil?
        new_shipment_line_item = Piggybak::LineItem.new({ :line_item_type => "shipment" })
        new_shipment_line_item.build_shipment
        self.line_items << new_shipment_line_item
      elsif shipment_line_item.shipment.nil?
        shipment_line_item.build_shipment
      else
        previous_method = shipment_line_item.shipment.shipping_method_id
        shipment_line_item.build_shipment
        shipment_line_item.shipment.shipping_method_id = previous_method
      end

      if !self.line_items.detect { |li| li.line_item_type == "payment" }
        payment_line_item = Piggybak::LineItem.new({ :line_item_type => "payment" })
        payment_line_item.build_payment 
        self.line_items << payment_line_item
      end
    end

    def add_line_items(cart)
      cart.update_quantities

      cart.sellables.each do |line_item|
        self.line_items << Piggybak::LineItem.new({ :sellable_id => line_item[:sellable].id,
          :unit_price => line_item[:sellable].situational_price(self.user),
          :price => line_item[:sellable].situational_price(self.user)*line_item[:quantity],
          :description => line_item[:sellable].description,
          :quantity => line_item[:quantity] })
      end
    end

    def update_status
      return if self.status == "cancelled"  # do nothing

      if self.total_due != 0.00
        self.status = "unbalanced" 
      else
        if self.to_be_cancelled
          self.status = "cancelled"
        elsif line_items.shipments.any? && line_items.shipments.all? { |li| li.shipment.status == "shipped" }
          self.status = "shipped"
        elsif line_items.shipments.any? && line_items.shipments.all? { |li| li.shipment.status == "processing" }
          self.status = "processing"
        else
          self.status = "new"
        end
      end
    end

    def set_new_record
      self.was_new_record = self.new_record?
      true
    end

    def status_enum
      ["new", "processing", "shipped"]
    end
      
    def avs_address
      {
      :address1 => self.billing_address.address1,
      :city     => self.billing_address.city,
      :state    => self.billing_address.state_display,
      :zip      => self.billing_address.zip,
      :country  => "US" 
      }
    end

    def admin_label
      "Order ##{self.id}"    
    end
  end
end
