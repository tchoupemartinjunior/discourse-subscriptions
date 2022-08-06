# frozen_string_literal: true
require_dependency "subscriptions_user_constraint"

DiscourseSubscriptions::Engine.routes.draw do
  scope 'admin' do
    get '/' => 'admin#index'
    post '/refresh' => 'admin#refresh_campaign'
    post '/create-campaign' => 'admin#create_campaign'
  end

  namespace :admin, constraints: AdminConstraint.new do
    resources :plans
    resources :subscriptions, only: [:index, :destroy]
    resources :products
    resources :coupons, only: [:index, :create]
    resource :coupons, only: [:destroy, :update]
  end

  namespace :user do
    resources :payments, only: [:index]
    resources :subscriptions, only: [:index, :update, :destroy]
  end

  get '/' => 'subscribe#index'
  get '.json' => 'subscribe#index'
  get '/contributors' => 'subscribe#contributors'
  get '/:id' => 'subscribe#show'
  post '/create' => 'subscribe#create'
  post '/finalize' => 'subscribe#finalize'

  # route for the creaton of payment intents
  post '/payment_intent' => 'subscribe#payment_intent'
   # route for the payment instructions page
  get '/instructions' => 'subscribe#instructions'

  post '/hooks' => 'hooks#create'

end
