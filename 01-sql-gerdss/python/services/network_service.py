"""
GERDSS Network & Transmission Loss Service / Netzdienst für Übertragungsverluste
Calculates power losses across transmission lines based on LossPercentage.
"""


class NetworkService:
    @staticmethod
    def calculate_net_delivery(gross_mwh: float, loss_percentage: float) -> dict:
        """
        Calculates net delivered energy and lost energy based on line loss percentage.
        Berechnet die gelieferte Nettoenergie und den Energieverlust.
        """
        if gross_mwh < 0:
            raise ValueError("gross_mwh must be non-negative")
        if not 0 <= loss_percentage <= 100:
            raise ValueError("loss_percentage must be between 0 and 100")

        loss_mwh = gross_mwh * (loss_percentage / 100.0)
        net_mwh = gross_mwh - loss_mwh

        return {
            "GrossMWh": float(gross_mwh),
            "LossPercentage": float(loss_percentage),
            "LossMWh": float(loss_mwh),
            "NetDeliveredMWh": float(net_mwh),
        }
