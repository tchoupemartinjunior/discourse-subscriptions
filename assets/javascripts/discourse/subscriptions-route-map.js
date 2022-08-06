
export default function () {
  this.route("subscribe", { path: "/s" }, function () {
    this.route("show", { path: "/:subscription-id" });
    this.route("payment_intent", { path: "/payment_intent" });
    this.route("instructions", { path: "/instructions" });
   
    });
  };  
  
