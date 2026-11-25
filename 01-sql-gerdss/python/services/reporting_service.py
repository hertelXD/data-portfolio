import math
from pathlib import Path
import pandas as pd
from datetime import datetime


class ReportingService:
    @staticmethod
    def export_allocation_to_csv(
        allocations_data: list, filename: str = "gerdss_allocation_report.csv"
    ) -> str:
        required_columns = [
            "PlantID",
            "PlantName",
            "AllocatedMWh",
            "CO2Factor",
            "CO2EmittedTons",
        ]
        df = pd.DataFrame(allocations_data)
        missing = [column for column in required_columns if column not in df.columns]
        if missing:
            raise ValueError(f"Missing allocation columns: {', '.join(missing)}")
        output_path = Path(filename)
        if not output_path.is_absolute():
            output_path = Path(__file__).resolve().parents[1] / output_path
        output_path.parent.mkdir(parents=True, exist_ok=True)
        df["ExportedAt"] = datetime.now().strftime("%Y%m%d %H:%M:%S")
        df.to_csv(output_path, index=False, encoding="utf-8-sig")

        sql_filename = output_path.with_name("insert_query.sql")
        with sql_filename.open("w", encoding="utf-8") as f:
            f.write("USE dbGERDSS;\nGO\n\n")
            f.write("TRUNCATE TABLE dbo.Allocations;\nGO\n\n")
            f.write(
                "INSERT INTO dbo.Allocations (PlantID, PlantName, AllocatedMWh, CO2Factor, CO2EmittedTons, ExportedAt)\nVALUES\n"
            )

            values = []
            for _, row in df.iterrows():
                plant_name = str(row["PlantName"]).replace("'", "''")
                numeric_values = [
                    row[column] for column in required_columns if column != "PlantName"
                ]
                if any(
                    pd.isna(value) or not math.isfinite(float(value))
                    for value in numeric_values
                ):
                    raise ValueError("Allocation data contains invalid numeric values")
                values.append(
                    f"({int(row['PlantID'])}, N'{plant_name}', {row['AllocatedMWh']}, {row['CO2Factor']}, {row['CO2EmittedTons']}, '{row['ExportedAt']}')"
                )
            f.write(",\n".join(values) + ";\nGO\n")

        return str(output_path)
