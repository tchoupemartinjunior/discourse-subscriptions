# frozen_string_literal: true

module DiscourseSubscriptions
  class SubscribeController < ::ApplicationController
    include DiscourseSubscriptions::Stripe
    include DiscourseSubscriptions::Group
    before_action :set_api_key
    protect_from_forgery except: :hooks
    requires_login except: [:index, :hooks, :contributors, :show]

    def instructions
    end

    def hooks
        event = nil
        payload = request.body.read
        sig_header = request.env['HTTP_STRIPE_SIGNATURE']
        webhook_secret = SiteSetting.discourse_subscriptions_webhook_secret
      begin 
        event = ::Stripe::Webhook.construct_event(payload, sig_header,  webhook_secret)
        print "***************************payment TCHOUPE**************************************************************************************************************************************"
    

      case event[:type]
      when 'payment_intent.succeeded'
        print "***************************payment TCHOUPE**************************************************************************************************************************************"
      
      else
        print "***************************payment TCHOUPE**************************************************************************************************************************************"
      end
      status 200
    end
    end

   

    def payment_intent
      params.require([:plan])
      begin
        customer = payment_intent_find_or_create_customer()
        plan = ::Stripe::Price.retrieve(params[:plan])
        product=plan[:product] if plan[:product]
        group=plan[:metadata][:group_name]
        nickname = plan[:nickname]
        unit_amount=plan[:unit_amount] if plan[:unit_amount]
       

        price =  unit_amount.to_i
        bk_payment_intent = ::Stripe::PaymentIntent.create({
          amount: price,
          currency: SiteSetting.discourse_subscriptions_currency,
          customer: customer[:id],
          description: nickname,
          metadata:{
             product:product,
             group_name:group,
             nickname:nickname,
             unit_amount:unit_amount
         
            },
          payment_method_types: ["customer_balance"],
          payment_method_data: {
            type: "customer_balance",
          },
          payment_method_options: {
            customer_balance: {
              funding_type: "bank_transfer",
              bank_transfer: {
                type: "eu_bank_transfer",
                eu_bank_transfer: {
                  country: "FR",
                }
              },
            },
          },
          confirm: true
        })
        print "***************************payment TCHOUPE**************************************************************************************************************************************"
        
      render json: bk_payment_intent
      end
    end

    def index
      begin
        product_ids = Product.all.pluck(:external_id)
        products = []

        if product_ids.present? && is_stripe_configured?
          response = ::Stripe::Product.list({
            ids: product_ids,
            active: true
          })

          products = response[:data].map do |p|
            serialize_product(p)
          end

        end

        render_json_dump products

      rescue ::Stripe::InvalidRequestError => e
        render_json_error e.message
      end
    end

    def contributors
      return unless SiteSetting.discourse_subscriptions_campaign_show_contributors
      contributor_ids = Set.new

      campaign_product = SiteSetting.discourse_subscriptions_campaign_product
      campaign_product.present? ? contributor_ids.merge(Customer.where(product_id: campaign_product).last(5).pluck(:user_id)) : contributor_ids.merge(Customer.last(5).pluck(:user_id))

      contributors = ::User.where(id: contributor_ids)

      render_serialized(contributors, UserSerializer)
    end

    def show
      params.require(:id)
      begin
        product = ::Stripe::Product.retrieve(params[:id])
        plans = ::Stripe::Price.list(active: true, product: params[:id])

        response = {
          product: serialize_product(product),
          plans: serialize_plans(plans)
        }

        render_json_dump response
      rescue ::Stripe::InvalidRequestError => e
        render_json_error e.message
      end
    end

    def create
      params.require([:source, :plan])
      begin
        customer = find_or_create_customer(params[:source])
        plan = ::Stripe::Price.retrieve(params[:plan])

        if params[:promo].present?
          promo_code = ::Stripe::PromotionCode.list({ code: params[:promo] })
          promo_code = promo_code[:data][0] # we assume promo codes have a unique name

          return render_json_error I18n.t("js.discourse_subscriptions.subscribe.invalid_coupon") if promo_code.blank?
        end

        recurring_plan = plan[:type] == 'recurring'

        if recurring_plan
          trial_days = plan[:metadata][:trial_period_days] if plan[:metadata] && plan[:metadata][:trial_period_days]

          promo_code_id = promo_code[:id] if promo_code

          transaction = ::Stripe::Subscription.create(
            customer: customer[:id],
            items: [{ price: params[:plan] }],
            metadata: metadata_user,
            trial_period_days: trial_days,
            promotion_code: promo_code_id
          )

          payment_intent = retrieve_payment_intent(transaction[:latest_invoice]) if transaction[:status] == 'incomplete'
        else
          coupon_id = promo_code[:coupon][:id] if promo_code && promo_code[:coupon] && promo_code[:coupon][:id]
          invoice_item = ::Stripe::InvoiceItem.create(
            customer: customer[:id],
            price: params[:plan],
            discounts: [{ coupon: coupon_id }]
          )
          invoice = ::Stripe::Invoice.create(
            customer: customer[:id]
          )
          transaction = ::Stripe::Invoice.finalize_invoice(invoice[:id])
          payment_intent = retrieve_payment_intent(transaction[:id]) if transaction[:status] == 'open'
          transaction = ::Stripe::Invoice.pay(invoice[:id]) if payment_intent[:status] == 'successful'
        end

        finalize_transaction(transaction, plan) if transaction_ok(transaction)

        transaction = transaction.to_h.merge(transaction, payment_intent: payment_intent)

        render_json_dump transaction
      rescue ::Stripe::InvalidRequestError => e
        render_json_error e.message
      end
    end

    def finalize
      params.require([:plan, :transaction])
      begin
        price = ::Stripe::Price.retrieve(params[:plan])
        transaction = retrieve_transaction(params[:transaction])
        finalize_transaction(transaction, price) if transaction_ok(transaction)

        render_json_dump params[:transaction]
      rescue ::Stripe::InvalidRequestError => e
        render_json_error e.message
      end
    end

    def finalize_transaction(transaction, plan)
      group = plan_group(plan)

      group.add(current_user) if group

      customer = Customer.create(
        user_id: current_user.id,
        customer_id: transaction[:customer],
        product_id: plan[:product]
      )

      if transaction[:object] == 'subscription'
        Subscription.create(
          customer_id: customer.id,
          external_id: transaction[:id]
        )
      end
    end

    private

    def serialize_product(product)
      {
        id: product[:id],
        name: product[:name],
        description: PrettyText.cook(product[:metadata][:description]),
        subscribed: current_user_products.include?(product[:id]),
        repurchaseable: product[:metadata][:repurchaseable]
      }
    end

    def current_user_products
      return [] if current_user.nil?

      Customer
        .select(:product_id)
        .where(user_id: current_user.id)
        .map { |c| c.product_id }.compact
    end

    def serialize_plans(plans)
      plans[:data].map do |plan|
        plan.to_h.slice(:id, :unit_amount, :currency, :type, :recurring)
      end.sort_by { |plan| plan[:amount] }
    end

    def find_or_create_customer(source)
      customer = Customer.find_by_user_id(current_user.id)

      if customer.present?
        ::Stripe::Customer.retrieve(customer.customer_id)
      else
        ::Stripe::Customer.create(
          email: current_user.email,
          source: source
        )
      end
    end

    # create customer for payment intent
    def payment_intent_find_or_create_customer()
      customer = Customer.find_by_user_id(current_user.id)

      if customer.present?
        ::Stripe::Customer.retrieve(customer.customer_id)
      else
        ::Stripe::Customer.create(
          email: current_user.email,
        )
      end
    end

    def retrieve_payment_intent(invoice_id)
      invoice = ::Stripe::Invoice.retrieve(invoice_id)
      ::Stripe::PaymentIntent.retrieve(invoice[:payment_intent])
    end

    def retrieve_transaction(transaction)
      begin
        case transaction
        when /^sub_/
          ::Stripe::Subscription.retrieve(transaction)
        when /^in_/
          ::Stripe::Invoice.retrieve(transaction)
        end
      rescue ::Stripe::InvalidRequestError => e
        e.message
      end
    end

    def metadata_user
      { user_id: current_user.id, username: current_user.username_lower }
    end

    def transaction_ok(transaction)
      %w[active trialing paid].include?(transaction[:status])
    end
  end
end
