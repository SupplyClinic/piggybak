module Piggybak
  class Payment < ActiveRecord::Base
    belongs_to :order
    belongs_to :payment_method
    belongs_to :line_item

    validates :status, presence: true
    validates_presence_of :stripe_token, :on => :create


    attr_accessor :number
    attr_accessor :verification_value
    attr_accessor :stripe_customer_id
    attr_accessor :stripe_token

    
    def status_enum
      ["paid", "pending"]
    end

    def month_enum
      1.upto(12).to_a
    end

    def year_enum
      Time.now.year.upto(Time.now.year + 10).to_a
    end

    def credit_card
      { "number" => self.number,
        "month" => self.month,
        "year" => self.year,
        "verification_value" => self.verification_value,
        "first_name" => self.line_item ? self.line_item.order.billing_address.firstname : nil,
        "last_name" => self.line_item ? self.line_item.order.billing_address.lastname : nil }
    end

    def process(order)
      return true if !self.new_record?
      logger = Logger.new("#{Rails.root}/#{Piggybak.config.logging_file}")
      total_due_integer = (order.total_due * 100).to_i
      if (total_due_integer == 0)
        self.attributes = { :transaction_id => "free of charge",
                            :masked_number => "N/A" }
        return true
      elsif order.user && order.user.payment_method != "card"
        self.attributes = { :transaction_id => "credit",
                            :masked_number => "N/A" }
        return true
      elsif total_due_integer < 100
        self.errors.add :payment_method_id, "Supply Clinic unfortunately can't process orders less than a dollar (unless they're completely free of charge). Please adjust your cart size accordingly."
        return false
      else
        calculator = ::Piggybak::PaymentCalculator::Stripe.new(self.payment_method)
        Stripe.api_key = calculator.secret_key
        begin
          if self.stripe_customer_id
            charge = Stripe::Charge.create({
                        :amount => total_due_integer,
                        :customer => self.stripe_customer_id,
                        :source => self.stripe_token,
                        :currency => "usd",
                        :capture => false
                      })
          else 
            charge = Stripe::Charge.create({
                        :amount => total_due_integer,
                        :source => self.stripe_token,
                        :currency => "usd",
                        :capture => false
                      })
          end
          
          self.attributes = { :transaction_id => charge.id,
                              :masked_number => charge.source.last4 }
          return true
        rescue Stripe::CardError, Stripe::InvalidRequestError => e
          logger.info "#{Stripe.api_key}#{e.message}"
          self.errors.add :payment_method_id, e.message
          return false
        end
      end
    end

    # Note: It is not added now, because for methods that do not store
    # user profiles, a credit card number must be passed
    # If encrypted credit cards are stored on the system,
    # this can be updated
    def refund
      # TODO: Create ActiveMerchant refund integration 
      return
    end

    def details
      if !self.new_record? 
        return "Payment ##{self.id} (#{self.created_at.strftime("%m-%d-%Y")}): " #+ 
          #"$#{"%.2f" % self.total}" reference line item total here instead
      else
        return ""
      end
    end

    validates_each :payment_method_id do |record, attr, value|
      if record.new_record?
        credit_card = ActiveMerchant::Billing::CreditCard.new(record.credit_card)
     
        if !credit_card.valid?
          credit_card.errors.each do |key, value|
            if value.any? && !["first_name", "last_name", "type"].include?(key)
              record.errors.add key, (value.is_a?(Array) ? value.join(', ') : value)
            end
          end
        end
      end
    end
  end
end
