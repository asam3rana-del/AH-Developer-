/// Margin check: rate (primary unit) cost (primary unit) se kam hai?
/// Cost 0 (maloom nahi) ya rate 0 (set nahi) ho to warning nahi.
bool isBelowCost(double rate, double cost) => rate > 0 && cost > 0 && rate < cost;
