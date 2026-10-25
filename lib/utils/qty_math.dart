/// Stock / qty ka float-noise se bachao.
///
/// Stock `double` hai: 0.1 + 0.2 = 0.30000000000000004, aur 0.3 - 0.30000000000000004 < 0 — isliye
/// "kaafi stock hai?" wale guards (`stock >= needed`, `stock + delta >= 0`) bilkul barabar qty par bhi
/// jhoota "stock kam hai" dete the, aur sync ke jama/ghata se alag devices par stock 1e-16 ke farq se
/// alag nikalta tha.
library;

/// Itna farq float noise hai, asli stock farq nahi (Stock Audit EPSILON se chhota).
const double kStockEpsilon = 1e-6;

/// Qty ko 6 decimal tak round (noise saaf; asli qty 3 decimal se zyada nahi hoti).
double roundQty(double v) => (v * 1e6).roundToDouble() / 1e6;

/// `stock` mein `needed` nikalne ki gunjaish hai? (float noise ki tolerance ke saath)
bool hasEnoughStock(double stock, double needed) => stock + kStockEpsilon >= needed;
