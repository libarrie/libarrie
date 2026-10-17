// Small progressive enhancements for the htmx UI. No eval, no inline code.
// - Announces server events (HX-Trigger "libarrie:announce") to screen readers.
// - After a swap, moves focus to a swapped-in alert so errors are noticed.
// - Reports network failures instead of failing silently.
(function () {
  "use strict";

  function announce(message) {
    var region = document.getElementById("announcer");
    if (!region) return;
    region.textContent = "";
    window.setTimeout(function () { region.textContent = message; }, 50);
  }

  document.addEventListener("libarrie:announce", function (event) {
    var detail = event.detail;
    announce(typeof detail === "string" ? detail : (detail && detail.value) || "Done");
  });

  document.addEventListener("htmx:afterSettle", function (event) {
    var target = event.detail && event.detail.target;
    if (!target || !target.querySelector) return;
    var alert = target.querySelector("[role='alert']");
    if (alert) {
      alert.setAttribute("tabindex", "-1");
      alert.focus();
      announce(alert.textContent.trim());
    }
  });

  document.addEventListener("htmx:sendError", function () {
    announce("The connection was lost. Check your network and try again.");
  });
})();
