from pathlib import Path
import pandas as pd
import numpy as np
from datetime import datetime
from config.db_config import DBConfig

try:
    import pyodbc
except ImportError:  # SQL Server is optional when using the CSV fallback.
    pyodbc = None


class DatabaseManager:
    """
    Klasse zur zentralen Verwaltung von Datenpfaden, Einlesen von CSV-Tabellen,
    Simulieren von ENTSO-E Kraftwerksdaten und Synchronisation mit SQL Server.
    """

    def __init__(self, base_dir=None):
        self.base_dir = (
            Path(base_dir) if base_dir else Path(__file__).resolve().parents[1]
        )
        self.data_dir = self.base_dir / "data"

        # Erstellt den Datenordner, falls er noch nicht existiert
        if not self.data_dir.exists():
            self.data_dir.mkdir(parents=True)
            print(f"-> Verzeichnis erstellt: {self.data_dir}")

    def get_file_path(self, filename):
        """Gibt den absoluten Pfad für eine Datei im Datenordner zurück."""
        return str(self.data_dir / filename)

    @staticmethod
    def _connection_string():
        if DBConfig.DB_TRUSTED_CONNECTION.lower() in {"yes", "true", "1"}:
            return (
                f"DRIVER={{{DBConfig.DB_DRIVER}}};"
                f"SERVER={DBConfig.DB_SERVER};DATABASE={DBConfig.DB_DATABASE};"
                "Trusted_Connection=yes;TrustServerCertificate=yes;"
            )
        return (
            f"DRIVER={{{DBConfig.DB_DRIVER}}};SERVER={DBConfig.DB_SERVER};"
            f"DATABASE={DBConfig.DB_DATABASE};UID={DBConfig.DB_USER};PWD={DBConfig.DB_PASSWORD};"
            "TrustServerCertificate=yes;"
        )

    @classmethod
    def _connect(cls):
        """Open SQL Server using the configured login timeout."""
        if pyodbc is None:
            raise RuntimeError("pyodbc is not installed")
        return pyodbc.connect(
            cls._connection_string(), timeout=DBConfig.DB_CONNECTION_TIMEOUT
        )

    @classmethod
    def read_table(cls, table_name, base_dir=None):
        """Read a supported table from SQL Server, falling back to its project CSV."""
        queries = {
            "Countries": "SELECT CountryID, CountryName, CountryCode, GridOperator, CreditLimitEUR, IsExporter, GridEmissionFactor FROM dbo.Countries",
            "PowerPlants": """SELECT p.PlantID, p.PlantName, p.MaxCapacityMW,
                pt.TypeName, pt.CO2EmissionFactor, pt.IsRenewable
                FROM dbo.PowerPlants AS p
                JOIN dbo.PowerPlantTypes AS pt ON pt.PlantTypeID = p.PlantTypeID""",
        }
        if table_name not in queries:
            raise ValueError(f"Unsupported table: {table_name}")

        if pyodbc is not None:
            try:
                with cls._connect() as connection:
                    return pd.read_sql_query(queries[table_name], connection)
            except (pyodbc.Error, OSError) as error:
                print(f"[WARN] SQL Server unavailable; using CSV fallback ({error}).")

        csv_path = Path(base_dir) if base_dir else Path(__file__).resolve().parents[1]
        csv_path = csv_path / "data" / f"{table_name}.csv"
        if not csv_path.exists():
            raise FileNotFoundError(
                f"Neither SQL table nor fallback file exists: {csv_path}"
            )
        return pd.read_csv(csv_path)

    @classmethod
    def read_local_table(cls, table_name, base_dir=None):
        """Read a local CSV without attempting a remote database connection."""
        root_dir = Path(base_dir) if base_dir else Path(__file__).resolve().parents[1]
        csv_path = root_dir / "data" / f"{table_name}.csv"
        if not csv_path.exists():
            raise FileNotFoundError(f"Local CSV file not found: {csv_path}")
        return pd.read_csv(csv_path)

    @classmethod
    def export_countries_to_sql_script(
        cls,
        csv_filename="data/Countries.csv",
        output_filename="countries_import.sql",
        base_dir=None,
    ):
        """Create a paste-ready SQL script for the existing Countries table."""
        root_dir = Path(base_dir) if base_dir else Path(__file__).resolve().parents[1]
        csv_path = Path(csv_filename)
        if not csv_path.is_absolute():
            csv_path = root_dir / csv_path
        output_path = root_dir / output_filename
        df = pd.read_csv(csv_path)
        required = [
            "CountryName",
            "CountryCode",
            "GridOperator",
            "CreditLimitEUR",
            "IsExporter",
            "GridEmissionFactor",
        ]
        missing = [column for column in required if column not in df.columns]
        if missing:
            raise ValueError(f"CSV is missing required columns: {', '.join(missing)}")

        def sql_string(value):
            return "N'" + str(value).replace("'", "''") + "'"

        values = []
        for row in df[required].itertuples(index=False, name=None):
            is_exporter = (
                1 if str(row[4]).strip().lower() in {"true", "1", "yes"} else 0
            )
            values.append(
                "("
                + ", ".join(
                    [
                        sql_string(row[0]),
                        sql_string(row[1]),
                        sql_string(row[2]),
                        f"{float(row[3]):.2f}",
                        str(is_exporter),
                        f"{float(row[5]):.4f}",
                    ]
                )
                + ")"
            )
        script = (
            "USE dbGERDSS;\nGO\n\n"
            "MERGE dbo.Countries AS target\n"
            "USING (VALUES\n"
            + ",\n".join(values)
            + ") AS source(CountryName, CountryCode, GridOperator, CreditLimitEUR, IsExporter, GridEmissionFactor)\n"
            "ON target.CountryCode = source.CountryCode\n"
            "WHEN MATCHED THEN UPDATE SET\n"
            "    CountryName = source.CountryName, GridOperator = source.GridOperator,\n"
            "    CreditLimitEUR = source.CreditLimitEUR, IsExporter = source.IsExporter,\n"
            "    GridEmissionFactor = source.GridEmissionFactor\n"
            "WHEN NOT MATCHED THEN INSERT "
            "(CountryName, CountryCode, GridOperator, CreditLimitEUR, IsExporter, GridEmissionFactor)\n"
            "VALUES (source.CountryName, source.CountryCode, source.GridOperator, source.CreditLimitEUR, source.IsExporter, source.GridEmissionFactor);\nGO\n"
        )
        output_path.write_text(script, encoding="utf-8")
        return str(output_path)

    @classmethod
    def sync_csv_to_sql_server(
        cls, csv_filename, table_name="Allocations", base_dir=None
    ):
        """Replace Allocation rows in SQL Server; return False when SQL is unavailable."""
        if table_name != "Allocations":
            raise ValueError(f"Unsupported sync table: {table_name}")
        if pyodbc is None:
            print("[WARN] pyodbc is not installed; SQL synchronization skipped.")
            return False

        csv_path = Path(csv_filename)
        if not csv_path.is_absolute():
            csv_path = (
                Path(base_dir) if base_dir else Path(__file__).resolve().parents[1]
            ) / csv_path
        df = pd.read_csv(csv_path)
        columns = [
            "PlantID",
            "PlantName",
            "AllocatedMWh",
            "CO2Factor",
            "CO2EmittedTons",
            "ExportedAt",
        ]
        missing = [column for column in columns if column not in df.columns]
        if missing:
            raise ValueError(f"CSV is missing required columns: {', '.join(missing)}")

        try:
            with cls._connect() as connection:
                cursor = connection.cursor()
                cursor.execute("TRUNCATE TABLE dbo.Allocations")
                cursor.fast_executemany = True
                values = [
                    tuple(row[column] for column in columns)
                    for _, row in df[columns].iterrows()
                ]
                cursor.executemany(
                    "INSERT INTO dbo.Allocations "
                    "(PlantID, PlantName, AllocatedMWh, CO2Factor, CO2EmittedTons, ExportedAt) "
                    "VALUES (?, ?, ?, ?, ?, ?)",
                    values,
                )
                connection.commit()
            print(f"[SUCCESS] Synchronized {len(df)} allocation rows to SQL Server.")
            return True
        except (pyodbc.Error, OSError) as error:
            print(f"[WARN] SQL synchronization failed: {error}")
            return False

    @classmethod
    def sync_powerplants_csv_to_sql_server(cls, csv_filename, base_dir=None):
        """Replace SQL Server power plants with rows from a compatible CSV."""
        if pyodbc is None:
            print("[WARN] pyodbc is not installed; power plant import skipped.")
            return False

        csv_path = Path(csv_filename)
        if not csv_path.is_absolute():
            csv_path = (
                Path(base_dir) if base_dir else Path(__file__).resolve().parents[1]
            ) / csv_path
        df = pd.read_csv(csv_path)
        columns = {
            "PlantID",
            "PlantName",
            "MaxCapacityMW",
            "TypeName",
            "CO2EmissionFactor",
            "IsRenewable",
        }
        missing = columns.difference(df.columns)
        if missing:
            raise ValueError(
                f"CSV is missing required columns: {', '.join(sorted(missing))}"
            )

        try:
            with cls._connect() as connection:
                cursor = connection.cursor()
                type_rows = (
                    df[["TypeName", "CO2EmissionFactor", "IsRenewable"]]
                    .drop_duplicates(subset=["TypeName"])
                    .itertuples(index=False, name=None)
                )
                type_rows = [
                    (type_name, float(co2_factor), bool(is_renewable))
                    for type_name, co2_factor, is_renewable in type_rows
                ]
                cursor.executemany(
                    "UPDATE dbo.PowerPlantTypes "
                    "SET CO2EmissionFactor = ?, IsRenewable = ? WHERE TypeName = ?; "
                    "IF NOT EXISTS (SELECT 1 FROM dbo.PowerPlantTypes WHERE TypeName = ?) "
                    "INSERT INTO dbo.PowerPlantTypes "
                    "(TypeName, CO2EmissionFactor, IsRenewable) VALUES (?, ?, ?)",
                    [
                        (
                            co2_factor,
                            is_renewable,
                            type_name,
                            type_name,
                            type_name,
                            co2_factor,
                            is_renewable,
                        )
                        for type_name, co2_factor, is_renewable in type_rows
                    ],
                )
                cursor.execute("DELETE FROM dbo.PowerPlants")
                plant_rows = []
                for row in df.itertuples(index=False):
                    cursor.execute(
                        "SELECT TOP 1 NodeID FROM dbo.GridNodes "
                        "WHERE CountryID = (SELECT CountryID FROM dbo.Countries WHERE CountryCode = 'DE')"
                    )
                    node = cursor.fetchone()
                    if node is None:
                        raise ValueError(
                            "A German GridNodes row is required before importing plants"
                        )
                    cursor.execute(
                        "SELECT PlantTypeID FROM dbo.PowerPlantTypes WHERE TypeName = ?",
                        row.TypeName,
                    )
                    plant_type_id = cursor.fetchone()[0]
                    plant_rows.append(
                        (
                            row.PlantID,
                            row.PlantName,
                            plant_type_id,
                            row.MaxCapacityMW,
                            node[0],
                        )
                    )
                cursor.execute("SET IDENTITY_INSERT dbo.PowerPlants ON")
                cursor.fast_executemany = True
                cursor.executemany(
                    "INSERT INTO dbo.PowerPlants "
                    "(PlantID, PlantName, PlantTypeID, MaxCapacityMW, NodeID) "
                    "VALUES (?, ?, ?, ?, ?)",
                    plant_rows,
                )
                cursor.execute("SET IDENTITY_INSERT dbo.PowerPlants OFF")
                connection.commit()
            print(f"[SUCCESS] Imported {len(df)} power plants to SQL Server.")
            return True
        except (pyodbc.Error, OSError) as error:
            print(f"[WARN] Power plant import failed: {error}")
            return False

    @classmethod
    def sync_countries_csv_to_sql_server(cls, csv_filename, base_dir=None):
        """Upsert all country rows from a complete CSV into SQL Server."""
        if pyodbc is None:
            print("[WARN] pyodbc is not installed; country import skipped.")
            return False

        csv_path = Path(csv_filename)
        if not csv_path.is_absolute():
            csv_path = (
                Path(base_dir) if base_dir else Path(__file__).resolve().parents[1]
            ) / csv_path
        df = pd.read_csv(csv_path)
        columns = [
            "CountryID",
            "CountryName",
            "CountryCode",
            "GridOperator",
            "CreditLimitEUR",
            "IsExporter",
            "GridEmissionFactor",
        ]
        missing = [column for column in columns if column not in df.columns]
        if missing:
            raise ValueError(f"CSV is missing required columns: {', '.join(missing)}")

        def as_bool(value):
            return str(value).strip().lower() in {"true", "1", "yes"}

        try:
            with cls._connect() as connection:
                cursor = connection.cursor()
                for row in df[columns].itertuples(index=False, name=None):
                    cursor.execute(
                        "IF EXISTS (SELECT 1 FROM dbo.Countries WHERE CountryID = ?) "
                        "UPDATE dbo.Countries SET CountryName = ?, CountryCode = ?, "
                        "GridOperator = ?, CreditLimitEUR = ?, IsExporter = ?, "
                        "GridEmissionFactor = ? WHERE CountryID = ? "
                        "ELSE INSERT INTO dbo.Countries "
                        "(CountryID, CountryName, CountryCode, GridOperator, "
                        "CreditLimitEUR, IsExporter, GridEmissionFactor) "
                        "VALUES (?, ?, ?, ?, ?, ?, ?)",
                        (
                            int(row[0]),
                            row[1],
                            row[2],
                            row[3],
                            float(row[4]),
                            as_bool(row[5]),
                            float(row[6]),
                            int(row[0]),
                            int(row[0]),
                            row[1],
                            row[2],
                            row[3],
                            float(row[4]),
                            as_bool(row[5]),
                            float(row[6]),
                        ),
                    )
                connection.commit()
            print(f"[SUCCESS] Imported {len(df)} countries to SQL Server.")
            return True
        except (pyodbc.Error, OSError) as error:
            print(f"[WARN] Country import failed: {error}")
            return False

    def generate_simulated_entsoe_data(self, num_plants=150):
        """
        Simuliert realistische ENTSO-E Kraftwerks- und Einspeisedaten
        für das deutsche Stromnetz (GERDSS-Modell) mit intelligenter Typenfilterung.
        """
        print("-> Generiere simulierte ENTSO-E Kraftwerksdaten...")

        np.random.seed(42)  # Fester Seed für reproduzierbare Ergebnisse
        plant_types = ["Solar", "WindOnshore", "WindOffshore", "Hydro", "Gas"]
        weights = [0.45, 0.25, 0.15, 0.05, 0.10]  # Statistische Verteilung der Typen

        data = []
        for i in range(1, num_plants + 1):
            p_type = np.random.choice(plant_types, p=weights)
            capacity = round(np.random.uniform(10.0, 500.0), 2)

            # Kapazitätsabhängige Zuweisung von erzeugter Energie (MWh)
            if p_type in ["Solar", "WindOnshore", "WindOffshore"]:
                allocated_mwh = round(capacity * np.random.uniform(0.2, 0.9), 3)
            elif p_type == "Hydro":
                allocated_mwh = round(capacity * np.random.uniform(0.5, 0.8), 3)
            else:
                allocated_mwh = round(capacity * np.random.uniform(0.1, 0.4), 3)

            co2_factor = (
                0.0
                if p_type in ["Solar", "WindOnshore", "WindOffshore", "Hydro"]
                else 0.45
            )
            co2_emitted = round(allocated_mwh * co2_factor, 4)

            data.append(
                {
                    "PlantID": i,
                    "PlantName": f"DE-Grid-{p_type}-{i:03d}",
                    "AllocatedMWh": allocated_mwh,
                    "CO2Factor": co2_factor,
                    "CO2EmittedTons": co2_emitted,
                    "ExportedAt": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                }
            )

        df_plants = pd.DataFrame(data)
        return df_plants

    def export_to_sql_insert_script(
        self, df, table_name="Allocations", filename="insert_query.sql"
    ):
        """
        Konvertiert einen Pandas DataFrame in SQL INSERT-Anweisungen mit Unicode-Unterstützung (N''),
        die direkt in SQL Server Management Studio ausgeführt werden können.
        """
        file_path = self.get_file_path(filename)

        sql_statements = []
        sql_statements.append("USE dbGERDSS;\nGO\n")
        sql_statements.append(f"TRUNCATE TABLE dbo.{table_name};\nGO\n")
        sql_statements.append(
            f"INSERT INTO dbo.{table_name} (PlantID, PlantName, AllocatedMWh, CO2Factor, CO2EmittedTons, ExportedAt)\nVALUES"
        )

        values_list = []
        for _, row in df.iterrows():
            val_str = f"({row['PlantID']}, N'{row['PlantName']}', {row['AllocatedMWh']}, {row['CO2Factor']}, {row['CO2EmittedTons']}, '{row['ExportedAt']}')"
            values_list.append(val_str)

        sql_statements.append(",\n".join(values_list) + ";\nGO")

        full_sql = "\n".join(sql_statements)

        with open(file_path, "w", encoding="utf-8") as f:
            f.write(full_sql)

        print(f"-> SQL Insert-Skript erfolgreich gespeichert unter: {file_path}")
        return file_path


# --- Test / Ausführung ---
if __name__ == "__main__":
    db_mgr = DatabaseManager()
    df_simulated = db_mgr.generate_simulated_entsoe_data(num_plants=100)
    db_mgr.export_to_sql_insert_script(
        df_simulated, table_name="Allocations", filename="insert_query.sql"
    )
