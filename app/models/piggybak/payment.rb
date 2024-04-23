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
      logger = Logger.new(STDOUT)
      total_due_integer = (order.total_due * 100).to_i
      if (total_due_integer == 0)
        if order.user && order.user.is_supervised?
          self.attributes = { :transaction_id => "credit", :masked_number => "N/A" }
        else
          self.attributes = { :transaction_id => "free of charge", :masked_number => "N/A" }
        end
        return true
      elsif total_due_integer < 100
        self.errors.add :payment_method_id, "Supply Clinic unfortunately can't process orders less than a dollar (unless they're completely free of charge). Please adjust your cart size accordingly."
        return false
      else
        calculator = ::Piggybak::PaymentCalculator::Stripe.new(self.payment_method)
        Stripe.api_key = calculator.secret_key

        begin
          payment_intent_attributes = stripe_attributes(order: order, total: total_due_integer)
          intent = Stripe::PaymentIntent.create(payment_intent_attributes)
          charge = intent&.charges&.first

          self.attributes = { :transaction_id => charge.id,
                              :masked_number  => charge.payment_method_details.card.last4 }
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

    def stripe_attributes(order:, total:)
      order_attrs = order_attributes(order)
      {
        currency: 'usd',
        confirm: true,
        payment_method: stripe_token,
        capture_method: 'manual',
        off_session: true,
        amount: total
      }.merge(order_attrs)
    end

    def order_attributes(order)
      metadata = order&.user&.metadata || {}
      metadata[:has_only_elevated_suspicion_items] = order&.only_elevated_suspicion_items?

      order_attrs = {}
      order_attrs[:metadata] = metadata
      order_attrs[:customer] = stripe_customer_id if stripe_customer_id

      if order.cvc_token.present?
        order_attrs[:payment_method_options] = {
          card: {
            cvc_token: order.cvc_token
          }
        }
      end

      order_attrs
    end

    def details
      if !self.new_record?
        return "Payment ##{self.id} (#{self.created_at.strftime("%m-%d-%Y")}): " #+
          #"$#{"%.2f" % self.total}" reference line item total here instead
      else
        return ""
      end
    end
  end
end
