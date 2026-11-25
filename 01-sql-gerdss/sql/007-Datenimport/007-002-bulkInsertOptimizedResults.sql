/*==============================================================================
  Projekt : GERDSS - German Energy Export Decision Support System
  Author  : Aileen Hertel
  Datei   : 007-002-bulkInsertOptimizedResults.sql
  Zweck   : Liest die Ergebnisdatei der externen Optimierung in die
            Schnittstellentabelle Allocations ein. Mehr nicht - gebucht wird in
            einem eigenen Schritt ueber das Testskript zu 004-003, damit jede
            Datei genau eine Aufgabe hat und beide sich nicht dasselbe
            Zeitfenster streitig machen.

            Wird nur gebraucht, wenn die externe Schicht keine direkte
            Verbindung zum SQL Server hat - sonst schreibt
            db_manager.sync_csv_to_sql_server die Zeilen selbst dorthin.
  Technik : TRUNCATE TABLE, CREATE OR ALTER VIEW als Einlesesicht,
            BULK INSERT mit FIELDTERMINATOR, ROWTERMINATOR, FIRSTROW und
            CODEPAGE

  Dateiformat: die Datei stammt aus reporting_service.py und ist deshalb
            KOMMA-getrennt, UTF-8 mit BOM, mit den Spalten
            PlantID, PlantName, AllocatedMWh, CO2Factor, CO2EmittedTons, ExportedAt
            in genau dieser Reihenfolge. FIRSTROW = 2 ueberspringt die
            Kopfzeile mitsamt der Byte-Order-Mark.

  EINTRAGEN: den Dateipfad in Abschnitt 2 und das Lieferziel in Abschnitt 3.
            Zum Dateipfad: Der Pfad wird vom
            SQL-Server-Dienst gelesen, nicht von SSMS - laeuft der Server auf
            einem anderen Rechner, muss die Datei dort liegen.
==============================================================================*/

USE dbGERDSS;
GO

SET ANSI_NULLS ON;                                           -- ISO-Standard fuer NULL-Vergleiche
GO

SET QUOTED_IDENTIFIER ON;                                    -- Erlaubt doppelt gesetzte Bezeichner
GO

/*------------------------------------------------------------------------------
  1. Schnittstellentabelle leeren
  Die Tabelle Allocations wird bereits in 001-002 angelegt. Hier wird sie nur
  geleert, damit der Import einen definierten Ausgangszustand hat - genau wie
  es die Python-Schicht mit ihrem TRUNCATE ebenfalls tut.
------------------------------------------------------------------------------*/
IF OBJECT_ID('dbo.Allocations') IS NULL
    THROW 50010, 'Die Tabelle Allocations fehlt. Zuerst 001-002 ausfuehren.', 1;
GO

TRUNCATE TABLE dbo.Allocations;
GO

-- Einlesesicht: genau die sechs Spalten der Datei, in ihrer Reihenfolge.
CREATE OR ALTER VIEW dbo.vwAllocationsImport
AS
SELECT  PlantID,
        PlantName,
        AllocatedMWh,
        CO2Factor,
        CO2EmittedTons,
        ExportedAt
FROM dbo.Allocations;
GO

/*------------------------------------------------------------------------------
  2. CSV-Datei einlesen
------------------------------------------------------------------------------*/
-- BULK INSERT kennt keine Spaltenliste: es ordnet die Felder der Datei den
-- Spalten der Zieltabelle der Reihe nach zu. Allocations hat aber vorne einen
-- Schluessel und hinten einen Zeitstempel, die in der Datei nicht vorkommen.
-- Deshalb wird ueber eine Sicht eingelesen, die genau die sechs Dateispalten
-- in der Reihenfolge der Datei zeigt.
BULK INSERT dbo.vwAllocationsImport
FROM 'C:\SQL-Kurs\SQL-GERDSS\007-Datenimport\optimized_results.csv'
WITH (
    FIRSTROW        = 2,          -- Kopfzeile ueberspringen
    FIELDTERMINATOR = ',',        -- pandas schreibt mit Komma
    ROWTERMINATOR   = '0x0a',     -- Zeilenumbruch
    CODEPAGE        = '65001',    -- UTF-8
    TABLOCK
);
GO

SELECT * FROM dbo.Allocations;
GO

/*------------------------------------------------------------------------------
  Kontrolle: die Rohdaten liegen ungeprueft in der Schnittstellentabelle

  Erwartet werden 13 Zeilen. Elf davon sind gueltig und ergeben zusammen
  5000 MWh. Zwei sind absichtlich fehlerhaft und werden erst beim Uebernehmen
  abgelehnt:
    PlantID 999            - ein Kraftwerk, das es nicht gibt
    DE-Grid-Coal-018       - 9999 MWh, mehr als seine Nennleistung
------------------------------------------------------------------------------*/
SELECT  AllocationRowID, PlantID, PlantName, AllocatedMWh,
        CO2Factor, CO2EmittedTons, ExportedAt, ImportiertAm
FROM dbo.Allocations
ORDER BY AllocationRowID;
GO

SELECT COUNT(*) AS EingeleseneZeilen FROM dbo.Allocations;   -- erwartet: 13
GO

/*==============================================================================
  Naechster Schritt

  Gebucht wird ueber 004-003-spImportOptimizedResults_Testskript.sql. Dort
  werden die Zeilen einzeln geprueft, die gueltigen Mengen summiert und ueber
  spExecuteEnergyExport gebucht - auch importierte Daten laufen damit durch
  alle drei Pruefstufen.
==============================================================================*/
