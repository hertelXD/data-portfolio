# 008 - Externe Optimierung

Externe Optimierungsschicht des GERDSS-Projekts. Sie waehlt die Kraftwerke aus,
verteilt die Liefermenge und schreibt das Ergebnis als CSV. Die Buchung selbst
findet in der Datenbank statt, nicht hier.

## Ablauf

1. `data/PowerPlants.csv` und `data/Countries.csv` werden eingelesen.
   Beide Dateien entsprechen den Stammdaten aus `001-006-insertStammdaten.sql`:
   gleiche Kraftwerksnummern, gleiche Namen, gleiche Technologien und
   CO2-Faktoren, gleiche Laender.
2. Aus den erneuerbaren Anlagen werden die leistungsstaerksten ausgewaehlt.
3. Die Zielmaerkte werden nach dem Emissionsfaktor ihres Netzes sortiert:
   je schmutziger das Zielnetz, desto groesser die Einsparung durch deutschen
   Gruenstrom. Ergebnis in `data/target_markets.csv`.
4. Die Liefermenge wird nach Merit Order verteilt - niedrigster CO2-Faktor
   zuerst.
5. Uebertragungsverlust und Auftragswert werden berechnet und gegen den
   Kreditrahmen geprueft.
6. Das Ergebnis wird als `optimized_results.csv` geschrieben.

## Schnittstelle zur Datenbank

`optimized_results.csv`, komma-getrennt, UTF-8 mit BOM, Spalten in dieser
Reihenfolge:

    PlantID, PlantName, AllocatedMWh, CO2Factor, CO2EmittedTons, ExportedAt

Weiterverarbeitung in SQL Server:

1. `007-002-bulkInsertOptimizedResults.sql` liest die Datei nach `Allocations`.
2. `004-003-spImportOptimizedResults` bucht die Zeilen ueber
   `spExecuteEnergyExport` und traegt die Kraftwerksanteile in
   `TransactionPlantAllocations` ein.

## Start

    pip install -r requirements.txt
    python main.py

Das Programm fragt, wie viele Kraftwerke beliefert werden sollen. Die
Ergebnisdatei liegt danach im Projektordner.

Tests:

    python -m pytest tests

## Hinweis zur Datenbankverbindung

`config/db_config.py` liest die Verbindungsdaten aus Umgebungsvariablen. Ohne
Verbindung arbeitet das Programm mit den CSV-Dateien im Ordner `data`. Die
Zugangsdaten liegen bewusst nicht im Projekt.
