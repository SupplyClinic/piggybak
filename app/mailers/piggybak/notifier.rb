module Piggybak
  class Notifier < ActionMailer::Base
    default :from => Piggybak.config.email_sender,
            :cc => Piggybak.config.order_cc

    def order_notification(order, email=nil)
      @order = order
      if email = nil
        email = order.email
      end
      mail(:to => email,
           :subject => "Order Confirmation ##{sprintf '%06d', @order.id}")
    end
  end
end
