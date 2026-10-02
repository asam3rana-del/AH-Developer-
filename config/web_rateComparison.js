// ================================================================
// rateComparison.js — port of RateComparisonActivity.kt. Pick an item, see
// its purchase history grouped by supplier: last rate, lowest, highest, and
// how many times it's been bought — so the next purchase can go to whoever
// gave the best rate. Rates are normalized to the product's PRIMARY unit
// (same toPrimaryUnitRate idea Android uses) so a purchase entered in
// "Ctn" and another in "pcs" still compare fairly.
// ================================================================

import { products, suppliers, loadPurchaseHistory } from "./data.js";
import { unitLadder, smallestUnitFactor } from "./firebase-init.js";
import { getSession } from "./auth.js";

// Purchase / cost information is Admin + Manager only (same as Android's
// Item Search). Cashier never sees it and the purchase history is never even
// loaded for them.
function canSeeCost() {
  const role = (getSession() || {}).role;
  return role === "admin" || role === "manager";
}

function fmtRate(n) {
  const v = n || 0;
  return "Rs " + (Number.isInteger(v)
    ? v.toLocaleString("en-PK")
    : v.toLocaleString("en-PK", { minimumFractionDigits: 2, maximumFractionDigits: 2 }));
}

// salePrice / wholesalePrice are stored per PRIMARY unit; convert to a tier.
function rateInTier(product, primaryRate, tier) {
  const factor = smallestUnitFactor(product);
  return tier.smallestPerUnit > 0 && factor > 0 ? primaryRate / (factor / tier.smallestPerUnit) : primaryRate;
}

// Largest tier first: "Ctn Rs 2,880 • Dzn Rs 720 • Pcs Rs 60"
function tierRateLine(product, primaryRate) {
  return unitLadder(product).slice().reverse()
    .map(t => `${t.unit} ${fmtRate(rateInTier(product, primaryRate, t))}`)
    .join("  •  ");
}

function matchesQuery(p, q) {
  const hay = `${p.name || ""} ${p.searchTag || ""}`.toLowerCase();
  return q.toLowerCase().split(/\s+/).filter(Boolean).every(t => hay.includes(t));
}

function el(id) { return document.getElementById(id); }

function money(n) {
  return "Rs " + (n || 0).toLocaleString("en-PK", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

let cachedPurchases = null; // invalidated on every screen entry, see refresh() below
let selectedProduct = null;

function normalizedRate(product, rate, fromUnit) {
  const ladder = unitLadder(product);
  const tier = ladder.find(t => (t.unit || "").trim().toLowerCase() === (fromUnit || "").trim().toLowerCase())
    || ladder[ladder.length - 1];
  const ratePerSmallest = tier.smallestPerUnit > 0 ? rate / tier.smallestPerUnit : rate;
  return ratePerSmallest * smallestUnitFactor(product);
}

// ---------- Product picker ----------
function renderSuggestions(matches) {
  const box = el("rateCompareSuggestions");
  if (!matches.length) { box.classList.add("hidden"); box.innerHTML = ""; return; }
  box.innerHTML = "";
  matches.slice(0, 8).forEach(p => {
    const d = document.createElement("div");
    d.innerHTML = `<div><b></b></div><div class="muted" style="font-size:12px;"></div>`;
    d.querySelector("b").textContent = p.name;
    d.lastChild.textContent = p.salePrice > 0 ? tierRateLine(p, p.salePrice) : "Sale rate set nahi";
    d.addEventListener("click", () => selectProduct(p));
    box.appendChild(d);
  });
  box.classList.remove("hidden");
}

function renderSaleRateCard(product) {
  const box = el("rateCompareSaleCard");
  box.innerHTML = "";
  const card = document.createElement("div");
  card.className = "rate-row is-latest";
  let html = `<div class="muted" style="font-weight:700; letter-spacing:.5px;">SALE RATE</div>`;
  if (product.salePrice > 0) {
    unitLadder(product).slice().reverse().forEach(t => {
      html += `<div class="row-between" style="align-items:center; padding:2px 0;">
        <span class="muted" style="font-size:15px;">${t.unit}</span>
        <span style="font-size:24px; font-weight:800;">${fmtRate(rateInTier(product, product.salePrice, t))}</span>
      </div>`;
    });
  } else {
    html += `<p class="muted">Is item ka sale rate abhi set nahi hai</p>`;
  }
  if (product.wholesalePrice > 0) {
    html += `<hr style="border:none; border-top:1px solid var(--border, #E3E8EE); margin:10px 0;">
      <div class="muted" style="font-weight:700;">Wholesale: ${tierRateLine(product, product.wholesalePrice)}</div>`;
  }
  card.innerHTML = html;
  box.appendChild(card);
}

async function selectProduct(product) {
  selectedProduct = product;
  el("rateCompareSuggestions").classList.add("hidden");
  el("rateComparePicker").classList.add("hidden");
  el("rateCompareResult").classList.remove("hidden");
  el("rateCompareProductName").textContent = "📦 " + product.name;
  renderSaleRateCard(product);

  // Cost section: Admin/Manager only, closed by default, loaded on demand.
  const costBox = el("rateCompareCostBox");
  const costBtn = el("btnRateCompareShowCost");
  const list = el("rateCompareList");
  list.classList.add("hidden");
  list.innerHTML = "";
  costBtn.textContent = "Show cost ▾";
  if (!canSeeCost()) { costBox.classList.add("hidden"); return; }
  costBox.classList.remove("hidden");
  el("rateCompareSubtext").textContent = `Supplier rates per ${product.unit} (kisi bhi unit se convert karke)`;
}

async function toggleCost() {
  const list = el("rateCompareList");
  const btn = el("btnRateCompareShowCost");
  if (!canSeeCost() || !selectedProduct) return;
  if (!list.classList.contains("hidden")) {
    list.classList.add("hidden");
    btn.textContent = "Show cost ▾";
    return;
  }
  list.classList.remove("hidden");
  btn.textContent = "Hide cost ▴";
  list.innerHTML = "<p class='muted'>Loading purchase history…</p>";
  const product = selectedProduct;
  try {
    if (!cachedPurchases) cachedPurchases = await loadPurchaseHistory();
    if (selectedProduct === product) renderComparison(computeRows(product));
  } catch (e) {
    list.innerHTML = `<p class="muted">Error: ${e.message}</p>`;
  }
}

// ---------- Comparison math ----------
function computeRows(product) {
  const bySupplier = new Map(); // supplierServerId -> [{rate, createdAt}]

  cachedPurchases.forEach(purchase => {
    if (!purchase.supplierServerId) return;
    (purchase.items || []).forEach(it => {
      if (it.barcode !== product.barcode) return;
      const rate = normalizedRate(product, it.unitCost, it.unit || product.unit);
      const bucket = bySupplier.get(purchase.supplierServerId) || [];
      bucket.push({ rate, createdAt: purchase.createdAt });
      bySupplier.set(purchase.supplierServerId, bucket);
    });
  });

  const rows = [];
  bySupplier.forEach((entries, supplierId) => {
    const supplier = suppliers.find(s => s.id === supplierId);
    if (!supplier) return; // supplier was deleted since
    const mostRecent = entries.reduce((a, b) => (b.createdAt > a.createdAt ? b : a));
    rows.push({
      supplierName: supplier.name,
      lastRate: mostRecent.rate,
      lastDate: mostRecent.createdAt,
      minRate: Math.min(...entries.map(e => e.rate)),
      maxRate: Math.max(...entries.map(e => e.rate)),
      timesPurchased: entries.length
    });
  });

  return rows.sort((a, b) => a.lastRate - b.lastRate); // best (lowest) first
}

// ---------- Rendering ----------
function renderComparison(rows) {
  const box = el("rateCompareList");
  box.innerHTML = "";

  if (!rows.length) {
    box.innerHTML = "<p class='muted' style='text-align:center; padding:30px 0;'>Is item ki koi purchase history kisi supplier se nahi mili.</p>";
    return;
  }

  rows.forEach((r, i) => {
    const isBest = i === 0 && rows.length > 1;
    const div = document.createElement("div");
    div.className = "rate-row" + (isBest ? " is-best" : "");
    div.innerHTML = `
      <div class="row-between">
        <div>
          <div><b>${r.supplierName}</b>${isBest ? '<span class="rate-badge badge-navy">BEST</span>' : ""}</div>
          <div class="muted">${r.timesPurchased} purchase${r.timesPurchased > 1 ? "s" : ""} • last: ${new Date(r.lastDate).toLocaleDateString("en-PK")}</div>
        </div>
        <div style="text-align:right;">
          <div style="font-weight:800;">${money(r.lastRate)}</div>
          <div class="muted">range ${money(r.minRate)} – ${money(r.maxRate)}</div>
        </div>
      </div>
    `;
    box.appendChild(div);
  });
}

function backToPicker() {
  selectedProduct = null;
  el("rateCompareResult").classList.add("hidden");
  el("rateComparePicker").classList.remove("hidden");
  el("rateCompareSearch").value = "";
  el("rateCompareSearch").focus();
}

export function initRateComparisonScreen() {
  el("rateCompareSearch").addEventListener("input", () => {
    const q = el("rateCompareSearch").value.trim().toLowerCase();
    if (!q) { el("rateCompareSuggestions").classList.add("hidden"); return; }
    renderSuggestions(products.filter(p => matchesQuery(p, q)));
  });
  el("btnRateCompareChange").addEventListener("click", backToPicker);
  el("btnRateCompareShowCost").addEventListener("click", toggleCost);
}

/** Called by app.js whenever the Rate Comparison nav button is pressed —
 *  drops the purchase-history cache so a bill entered moments ago (this tab
 *  or another) is reflected next time an item is picked. */
export function refreshRateComparisonScreen() {
  cachedPurchases = null;
  if (!selectedProduct) {
    el("rateComparePicker").classList.remove("hidden");
    el("rateCompareResult").classList.add("hidden");
  }
}
