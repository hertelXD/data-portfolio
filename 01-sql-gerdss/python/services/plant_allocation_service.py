"""
GERDSS Plant Allocation Service / Kraftwerkszuordnungs-Dienst
Intelligently filters top 25 power plants from a massive pool of grid assets
strictly based on calculated cross-border green export volumes.
"""

from database.db_manager import DatabaseManager


class PlantAllocationService:
    @staticmethod
    def get_available_plants(number_of_plants=25):
        """
        Fetches German plants, keeps renewable plants, and selects the requested
        number by production and then by the lowest CO2 factor.
        """
        if not isinstance(number_of_plants, int) or isinstance(number_of_plants, bool):
            raise ValueError("number_of_plants must be an integer")
        if number_of_plants < 1:
            raise ValueError("number_of_plants must be at least 1")

        df_all_plants = DatabaseManager.read_local_table("PowerPlants")

        if df_all_plants.empty:
            return df_all_plants

        required_columns = {
            "PlantID",
            "PlantName",
            "MaxCapacityMW",
            "CO2EmissionFactor",
            "IsRenewable",
        }
        missing_columns = required_columns.difference(df_all_plants.columns)
        if missing_columns:
            raise ValueError(
                f"Missing plant columns: {', '.join(sorted(missing_columns))}"
            )

        renewable = df_all_plants["IsRenewable"].map(
            lambda value: value is True
            or str(value).strip().lower() in {"true", "1", "yes"}
        )
        df_green = df_all_plants.loc[renewable].copy()
        if df_green.empty:
            return df_green

        production_column = next(
            (
                column
                for column in ("ProductionMWh", "AllocatedMWh", "MaxCapacityMW")
                if column in df_green
            ),
            None,
        )
        if production_column is None:
            raise ValueError("No production column found")
        df_green["ProductionMWh"] = df_green[production_column].astype(float)
        if (df_green["ProductionMWh"] < 0).any() or (
            df_green["CO2EmissionFactor"] < 0
        ).any():
            raise ValueError("Production and CO2 factor must be non-negative")

        selected = (
            df_green.sort_values(
                by=["ProductionMWh", "CO2EmissionFactor", "PlantID"],
                ascending=[False, True, True],
                kind="mergesort",
            )
            .head(number_of_plants)
            .reset_index(drop=True)
        )

        print(
            f"[FILTER] Analyzed {len(df_all_plants)} plants; {len(df_green)} are green. "
            f"Selected {len(selected)} of {number_of_plants} requested plants."
        )
        return selected

    @staticmethod
    def calculate_total_emissions(allocations: list) -> float:
        """
        Calculates total CO2 emissions in tons for a given transaction allocation.
        """
        total_co2 = sum(float(item.get("CO2EmittedTons", 0.0)) for item in allocations)
        return float(total_co2)
