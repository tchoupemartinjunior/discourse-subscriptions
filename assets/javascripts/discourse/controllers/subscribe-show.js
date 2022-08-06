import Controller from "@ember/controller";
import Subscription from "discourse/plugins/discourse-subscriptions/discourse/models/subscription";
import Transaction from "discourse/plugins/discourse-subscriptions/discourse/models/transaction";
import I18n from "I18n";
import { not } from "@ember/object/computed";
import discourseComputed from "discourse-common/utils/decorators";
import bootbox from "bootbox";



export default Controller.extend({
  selectedPlan: null,
  promoCode: null,
  isAnonymous: not("currentUser"),
  instructions_url: null,
  isBank: false,
  isCard: false,



  init() {
    this._super(...arguments);
    this.set(
      "stripe",
      Stripe(this.siteSettings.discourse_subscriptions_public_key)
    );
    const elements = this.get("stripe").elements();

    this.set("cardElement", elements.create("card", { hidePostalCode: true }));
    this.set("isBank", false);
    this.set("isCard", false);
  },

  alert(path) {
    bootbox.alert(I18n.t(`discourse_subscriptions.${path}`));
  },

  @discourseComputed("model.product.repurchaseable", "model.product.subscribed")
canPurchase(repurchaseable, subscribed) {
  if (!repurchaseable && subscribed) {
    return false;
  }
  return true;
},



createPaymentIntent(plan) {
  console.log("subscriptions junior");
  const planId = this.selectedPlan;
  console.log(planId);
  const subscription = Subscription.payment_intent(planId);
  subscription.then((result) => {
    if (result.status == "requires_action") {
      const instructions_url = result.next_action.display_bank_transfer_instructions.hosted_instructions_url;
      console.log((instructions_url));
    }

  }).catch(e => {
    console.log(e);
  })


},


createSubscription(plan) {
  return this.stripe.createToken(this.get("cardElement")).then((result) => {
    if (result.error) {
      this.set("loading", false);
      return result;
    } else {
      const subscription = Subscription.create({
        source: result.token.id,
        plan: plan.get("id"),
        promo: this.promoCode,
      });

      return subscription.save();
    }
  });
},

handleAuthentication(plan, transaction) {
  return this.stripe
    .confirmCardPayment(transaction.payment_intent.client_secret)
    .then((result) => {
      if (
        result.paymentIntent &&
        result.paymentIntent.status === "succeeded"
      ) {
        return result;
      } else {
        this.set("loading", false);
        bootbox.alert(result.error.message || result.error);
        return result;
      }
    });
},

_advanceSuccessfulTransaction(plan) {
  this.alert("plans.success");
  this.set("loading", false);

  this.transitionToRoute(
    plan.type === "recurring"
      ? "user.billing.subscriptions"
      : "user.billing.payments",
    this.currentUser.username.toLowerCase()
  );
},

actions: {
  showConfirmModal() {
    this.set("showModal",true);
  },
  closeModal(){
    this.set("showModal",false);
  },

  setBankPaymentMethod(){
    this.set("showModal",false);
    this.set("loading", true);
    this.set("isBank", true);
    this.set("isCard", false);
    this.set("loading", false);
  },
  setCardPaymentMethod(){
    this.set("showModal",false);
    this.set("loading", true);
    this.set("isBank", false);
    this.set("isCard", true);
    this.set("loading", false);
  },

  paymentIntentHandler() {
    this.set("showModal",false);
    this.set("loading", true);
    const plan = this.get("model.plans")
      .filterBy("id", this.selectedPlan)
      .get("firstObject");

    if (!plan) {
      this.alert("plans.validate.payment_options.required");
      this.set("loading", false);
      return;
    }
    const planId = this.selectedPlan;
    const subscription = Subscription.payment_intent(planId);
    subscription.then((result) => {
      if (result.status == "requires_action") {
        const instructions_url = result.next_action.display_bank_transfer_instructions.hosted_instructions_url;
        bootbox.alert("The necessary instructions to finalise the payment have been sent to you by email.");
        window.location.replace("instructions");
      }

    }).catch(e => {
      console.log(e);
    })

    this.set("loading", false);
 
  },

  stripePaymentHandler() {
    this.set("loading", true);
    const plan = this.get("model.plans")
      .filterBy("id", this.selectedPlan)
      .get("firstObject");

    if (!plan) {
      this.alert("plans.validate.payment_options.required");
      this.set("loading", false);
      return;
    }

    let transaction = this.createSubscription(plan);

    transaction
      .then((result) => {
        if (result.error) {
          bootbox.alert(result.error.message || result.error);
        } else if (
          result.status === "incomplete" ||
          result.status === "open"
        ) {
          const transactionId = result.id;
          const planId = this.selectedPlan;
          this.handleAuthentication(plan, result).then(
            (authenticationResult) => {
              if (authenticationResult && !authenticationResult.error) {
                return Transaction.finalize(transactionId, planId).then(
                  () => {
                    this._advanceSuccessfulTransaction(plan);
                  }
                );
              }
            }
          );
        } else {
          this._advanceSuccessfulTransaction(plan);
        }
      })
      .catch((result) => {
        bootbox.alert(
          result.jqXHR.responseJSON.errors[0] || result.errorThrown
        );
        this.set("loading", false);
      });
  },
},
});
