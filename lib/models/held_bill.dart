/// Mirrors `data class HeldBill` (table: held_bills, PK: holdId).
///
/// [holdId] prefix tells the two screens apart: `HOLD...` = Sale,
/// `PHOLD...` = Purchase (see allSaleHolds / allPurchaseHolds in Database.kt).
class HeldBill {
  final String holdId;
  final String payload;
  final int createdAt;

  const HeldBill({
    required this.holdId,
    required this.payload,
    required this.createdAt,
  });

  Map<String, Object?> toMap() => {
        'holdId': holdId,
        'payload': payload,
        'createdAt': createdAt,
      };

  factory HeldBill.fromMap(Map<String, Object?> m) => HeldBill(
        holdId: m['holdId'] as String,
        payload: m['payload'] as String,
        createdAt: (m['createdAt'] as num).toInt(),
      );
}
