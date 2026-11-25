"""
GERDSS Main Pipeline / Haupt-Pipeline
Executes the cross-border energy trading pipeline, optimization, financial validation, and CSV export.
"""

import pandas as pd

from services.plant_allocation_service import PlantAllocationService
from services.optimization_service import OptimizationService
from services.network_service import NetworkService
from services.financial_service import FinancialService
from services.reporting_service import ReportingService
from database.db_manager import DatabaseManager


def prompt_for_number_of_plants(total_plants):
    """Read and validate the requested number of plants from the user."""
    while True:
        try:
            number = int(
                input(f"How many green plants should be exported (1-{total_plants})? ")
            )
        except ValueError:
            print("[ERROR] Please enter a whole number.")
            continue
        if 1 <= number <= total_plants:
            return number
        print(f"[ERROR] Enter a number between 1 and {total_plants}.")


def main():
    db_manager = DatabaseManager()
    print("==================================================")
    print("GERDSS CROSS-BORDER ENERGY TRADING ENGINE - PIPELINE & CSV")
    print("==================================================")

    # 1. Count plants and ask for the requested result size.
    print("\n[INFO] Checking total power plants...")
    all_plants = db_manager.read_local_table("PowerPlants")
    total_plants = len(all_plants)
    print(f"[INFO] Total power plants available: {total_plants}")
    if total_plants == 0:
        print("[ERROR] No power plants available.")
        return
    green_plants = all_plants["IsRenewable"].map(
        lambda value: value is True
        or str(value).strip().lower() in {"true", "1", "yes"}
    )
    total_green_plants = int(green_plants.sum())
    print(f"[INFO] Green power plants available: {total_green_plants}")
    if total_green_plants == 0:
        print("[ERROR] No green power plants available.")
        return
    number_of_plants = prompt_for_number_of_plants(total_green_plants)

    print("\n[INFO] Filtering green plants and selecting by production/pollution...")
    df_plants = PlantAllocationService.get_available_plants(number_of_plants)

    if df_plants.empty:
        print("[ERROR] No plants available or failed to fetch data.")
        return

    print(f"[SUCCESS] Loaded top {len(df_plants)} plants successfully.")

    # 1.5. Fetch Countries data to evaluate target carbon-aware routing (Destination Optimization)
    print(
        "\n[INFO] Fetching target countries emission factors for Carbon-Aware Routing..."
    )
    df_countries = db_manager.read_local_table("Countries")
    target_priorities = OptimizationService.allocate_target_countries_merit_order(
        df_countries
    )
    if target_priorities:
        print(f"-> Target markets loaded: {len(target_priorities)}")
        print("-> Target markets for German green-energy exports:")
        for priority, target in enumerate(target_priorities, start=1):
            print(
                f"   {priority:02d}. {target['CountryName']} ({target['CountryCode']}) "
                f"- Grid emission factor: {target['GridEmissionFactor']}"
            )
        target_market_path = db_manager.get_file_path("target_markets.csv")
        pd.DataFrame(target_priorities).to_csv(target_market_path, index=False)
        print(f"-> Complete target-market CSV saved at: {target_market_path}")

    # 2. Define sample trading parameters (Demand, Price, Loss, Credit Limit)
    required_mwh = 5000.0  # Target energy demand
    price_per_mwh = 85.0  # EUR per MWh
    loss_percentage = 2.5  # Transmission loss %
    credit_limit_eur = 600000.0
    active_deals_eur = 150000.0

    # 3. Optimization (Merit Order allocation - Source)
    print(
        "\n[STAGE 1: OPTIMIZATION (SOURCE - Clean Merit Order)] Running Merit Order allocation..."
    )
    allocations = OptimizationService.allocate_power_merit_order(
        df_plants, required_mwh
    )

    total_allocated_mwh = sum(item["AllocatedMWh"] for item in allocations)
    total_co2 = sum(item["CO2EmittedTons"] for item in allocations)
    print(f"-> Total Allocated Energy: {total_allocated_mwh:.2f} MWh")
    print(f"-> Total CO2 Emissions: {total_co2:.2f} Tons")

    # 4. Network Loss Calculation
    print("\n[STAGE 2: NETWORK TRANSMISSION] Calculating net delivery...")
    net_result = NetworkService.calculate_net_delivery(
        total_allocated_mwh, loss_percentage
    )
    print(
        f"-> Net Delivered Energy: {net_result['NetDeliveredMWh']:.2f} MWh (Loss: {net_result['LossMWh']:.2f} MWh)"
    )

    # 5. Financial Validation
    print("\n[STAGE 3: FINANCIAL & CREDIT RISK] Validating transaction value...")
    deal_value = FinancialService.calculate_transaction_value(
        total_allocated_mwh, price_per_mwh
    )
    credit_status = FinancialService.validate_credit_limit(
        credit_limit_eur, active_deals_eur, deal_value
    )
    print(f"-> Deal Value: {deal_value:,.2f} EUR")
    print(
        f"-> Credit Approved: {credit_status['IsApproved']} (Remaining: {credit_status['RemainingCreditEUR']:,.2f} EUR)"
    )

    # 6. Export Results to CSV for SSMS Sync
    print("\n[STAGE 4: REPORTING & CSV SYNC] Generating report file...")
    # Dateiname der Ergebnisdatei. Genau dieser Name wird von
    # 007-002-bulkInsertOptimizedResults.sql eingelesen.
    csv_filename = "optimized_results.csv"
    report_path = ReportingService.export_allocation_to_csv(
        allocations, filename=csv_filename
    )

    print(
        "-> Datei per BULK INSERT einlesen: 007-002-bulkInsertOptimizedResults.sql"
    )

    print("\n==================================================")
    print("[PIPELINE COMPLETED SUCCESSFULLY]")
    print(f"Report saved at: {report_path}")
    print("==================================================")


if __name__ == "__main__":
    main()
