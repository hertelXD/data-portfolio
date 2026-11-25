"""
GERDSS Financial & Credit Risk Service / Finanz- und Kreditrisikodienst
Evaluates transaction value and validates against buyer country credit limits.
"""


class FinancialService:
    @staticmethod
    def calculate_transaction_value(mwh: float, price_per_mwh: float) -> float:
        """
        Calculates total transaction value in EUR.
        Berechnet den Gesamtwert der Transaktion in Euro.
        """
        if mwh < 0 or price_per_mwh < 0:
            raise ValueError("mwh and price_per_mwh must be non-negative")
        return float(mwh * price_per_mwh)

    @staticmethod
    def validate_credit_limit(
        credit_limit_eur: float, active_deals_total_eur: float, new_deal_eur: float
    ) -> dict:
        """
        Validates whether the new transaction exceeds the buyer's credit limit.
        Prüft, ob die neue Transaktion das Kreditlimit des Käufers überschreitet.
        """
        if min(credit_limit_eur, active_deals_total_eur, new_deal_eur) < 0:
            raise ValueError("credit values must be non-negative")

        projected_total = active_deals_total_eur + new_deal_eur
        is_approved = projected_total <= credit_limit_eur
        remaining_credit = (
            credit_limit_eur - projected_total
            if is_approved
            else credit_limit_eur - active_deals_total_eur
        )

        return {
            "IsApproved": is_approved,
            "CreditLimitEUR": float(credit_limit_eur),
            "ProjectedTotalEUR": float(projected_total),
            "RemainingCreditEUR": float(remaining_credit),
        }
