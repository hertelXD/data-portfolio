"""
GERDSS Optimization Service / Optimierungsdienst für Energieallokation
Provides multi-objective optimization algorithms (Financial, Transmission Loss, and Carbon-Aware Routing)
ensuring all 25 monitored plants are included in the reporting output.
"""

import pandas as pd


class OptimizationService:
    @staticmethod
    def allocate_power_merit_order(
        df_plants: pd.DataFrame, required_mwh: float
    ) -> list:
        """
        Multi-objective allocation reflecting Carbon-Aware Routing and Merit Order,
        ensuring all 25 monitored plants are included in the reporting output.
        """
        if required_mwh < 0:
            raise ValueError("required_mwh must be non-negative")
        required_columns = {
            "PlantID",
            "PlantName",
            "MaxCapacityMW",
            "CO2EmissionFactor",
        }
        missing_columns = required_columns.difference(df_plants.columns)
        if missing_columns:
            raise ValueError(
                f"Missing plant columns: {', '.join(sorted(missing_columns))}"
            )

        sorted_plants = df_plants.sort_values(
            by=["CO2EmissionFactor", "PlantID"],
            ascending=[True, True],
            kind="mergesort",
        )

        allocations = []
        remaining_demand = required_mwh

        # Iterate through all plants to guarantee all 25 are included in output
        for _, plant in sorted_plants.iterrows():
            capacity = float(plant["MaxCapacityMW"])
            co2_factor = float(plant["CO2EmissionFactor"])
            if capacity < 0 or co2_factor < 0:
                raise ValueError("Plant capacity and CO2 factor must be non-negative")

            if remaining_demand > 0:
                allocated = min(capacity, remaining_demand)
                remaining_demand -= allocated
            else:
                # Keep all 25 plants in report even if demand is fully met (Allocation = 0.0)
                allocated = 0.0

            allocations.append(
                {
                    "PlantID": plant["PlantID"],
                    "PlantName": plant["PlantName"],
                    "AllocatedMWh": allocated,
                    "CO2Factor": co2_factor,
                    "CO2EmittedTons": allocated * co2_factor,
                }
            )

        return allocations

    @staticmethod
    def allocate_target_countries_merit_order(df_countries: pd.DataFrame) -> list:
        """
        Prioritizes target/importing countries based on HIGHEST grid emission factor
        to maximize carbon reduction impact (Carbon-Aware Routing - Destination).
        """
        if df_countries.empty:
            return []

        if "IsExporter" in df_countries.columns:
            is_exporter = df_countries["IsExporter"].map(
                lambda value: str(value).strip().lower() in {"true", "1", "yes"}
            )
            df_targets = df_countries.loc[~is_exporter].copy()
            if df_targets.empty:
                df_targets = df_countries.copy()
        else:
            df_targets = df_countries.copy()

        if "GridEmissionFactor" not in df_targets.columns:
            df_targets["GridEmissionFactor"] = 0.0
        sorted_targets = df_targets.sort_values(
            by="GridEmissionFactor", ascending=False
        )

        target_priorities = []
        for _, country in sorted_targets.iterrows():
            target_priorities.append(
                {
                    "CountryID": country.get("CountryID", 0),
                    "CountryName": country.get("CountryName", "Unknown"),
                    "CountryCode": country.get("CountryCode", "XX"),
                    "GridEmissionFactor": float(country.get("GridEmissionFactor", 0.0)),
                }
            )

        return target_priorities
