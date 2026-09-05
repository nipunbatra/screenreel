"use strict";

// Style illustration only: no capture, uploads, timers or network requests.
const canvas = document.querySelector("#demo-canvas");
const padding = document.querySelector("#padding");
const focusToggle = document.querySelector("#focus-toggle");
const swatches = [...document.querySelectorAll("[data-look].swatch")];
const status = document.querySelector("#demo-status");

function updateDemo() {
  const focused = focusToggle.getAttribute("aria-pressed") === "true";
  canvas.style.setProperty("--demo-pad", `${padding.value}%`);
  canvas.classList.toggle("is-focused", focused);
  document.querySelector("#padding-value").textContent = `${padding.value}%`;
  const name = canvas.dataset.look;
  status.textContent = `${name[0].toUpperCase()}${name.slice(1)} background · ${padding.value}% padding · ${focused ? "detail view" : "full frame"}`;
}
swatches.forEach(button => button.addEventListener("click", () => {
  swatches.forEach(swatch => swatch.setAttribute("aria-pressed", String(swatch === button)));
  canvas.dataset.look = button.dataset.look;
  updateDemo();
}));
padding.addEventListener("input", updateDemo);
focusToggle.addEventListener("click", () => {
  focusToggle.setAttribute("aria-pressed", String(focusToggle.getAttribute("aria-pressed") !== "true"));
  updateDemo();
});
document.querySelector("#reset-demo").addEventListener("click", () => {
  canvas.dataset.look = "clay";
  padding.value = "9";
  focusToggle.setAttribute("aria-pressed", "false");
  swatches.forEach(button => button.setAttribute("aria-pressed", String(button.dataset.look === "clay")));
  updateDemo();
});
document.querySelectorAll("[data-copy]").forEach(button => {
  button.addEventListener("click", async () => {
    const source = document.getElementById(button.dataset.copy);
    const announcement = document.querySelector("#copy-status");
    try {
      await navigator.clipboard.writeText(source.textContent.trim());
      announcement.textContent = "Commands copied to your clipboard.";
      button.textContent = "Copied";
    } catch {
      const selection = window.getSelection();
      const range = document.createRange();
      range.selectNodeContents(source);
      selection.removeAllRanges();
      selection.addRange(range);
      announcement.textContent = "Commands selected. Press Command-C or Control-C to copy.";
      button.textContent = "Text selected";
    }
  });
});
