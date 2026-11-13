// Cargo Earth: Menu. A UI app with no phone of its own: it shows the Menu window (Garage, Home, Companies, Progress,
// Finances, Delivery map, Firm, Settings) when the floating phone or the phone on the dash asks for it, so the Menu
// works whichever phone is used. It is the phone app's own code in menu mode (CargoEarthPhone/app.js).
angular.module('beamng.apps')
.directive('cargoEarthMenu', [function () {
  return { template: '<cargo-earth-phone mode="menu" style="display:block;width:100%;height:100%"></cargo-earth-phone>' }
}]);
