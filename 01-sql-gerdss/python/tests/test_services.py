"""
GERDSS Unit Tests / Unit-Tests für سرویس‌های منطق پروژه
Tests mathematical calculations for Optimization, Network Losses, and Financials.
"""

import sys
import os
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import unittest
import pandas as pd
from services.optimization_service import OptimizationService
from services.network_service import NetworkService
from services.financial_service import FinancialService

class TestGERDSSServices(unittest.TestCase):

    def test_merit_order_allocation(self):
        """Tests if energy is allocated to lowest CO2 emitters first."""
        test_plants = pd.DataFrame({
            "PlantID": [1, 2],
            "PlantName": ["Dirty Plant", "Clean Plant"],
            "MaxCapacityMW": [100.0, 100.0],
            "CO2EmissionFactor": [0.900, 0.010]
        })
        results = OptimizationService.allocate_power_merit_order(test_plants, 50.0)

        # Clean plant must be picked first
        self.assertEqual(results[0]["PlantName"], "Clean Plant")
        self.assertEqual(results[0]["AllocatedMWh"], 50.0)

    def test_network_loss_calculation(self):
        """Tests 10% transmission loss calculation."""
        loss_data = NetworkService.calculate_net_delivery(100.0, 10.0)
        self.assertEqual(loss_data["LossMWh"], 10.0)
        self.assertEqual(loss_data["NetDeliveredMWh"], 90.0)

    def test_financial_credit_limit(self):
        """Tests credit limit approval and rejection thresholds."""
        check_pass = FinancialService.validate_credit_limit(1000.0, 200.0, 500.0)
        self.assertTrue(check_pass["IsApproved"])

        check_fail = FinancialService.validate_credit_limit(1000.0, 800.0, 500.0)
        self.assertFalse(check_fail["IsApproved"])

if __name__ == "__main__":
    unittest.main()