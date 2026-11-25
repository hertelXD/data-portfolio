/*==============================================================================
  Projekt : GERDSS - German Energy Export Decision Support System
  Author  : Aileen Hertel
  Datei   : 004-003-spImportOptimizedResults_Testskript.sql
  Zweck   : Testskript zur Importprozedur spImportOptimizedResults. Prueft den
            vollstaendigen Weg von der Zwischentabelle bis zur gebuchten
            Lieferung samt Kraftwerkszuteilung.
  Technik : SELECT mit Testfaellen, EXEC mit OUTPUT-Parametern, PRINT

  Voraussetzung: Die Tabelle Allocations ist gefuellt - entweder durch
            007-002 (CSV per BULK INSERT) oder direkt durch main.py der
            Python-Schicht.

  Zeitfenster: Test 2 bucht um 07:00 Uhr. Um 06:00 liegt bereits die Lieferung
            aus 004-002 (Test 1) mit 3000 MWh; dort waeren von den 5000 MWh der
            Leitung nur noch 2000 frei, und der Import wuerde an Stufe 1
            scheitern.
==============================================================================*/

USE dbGERDSS;
GO

PRINT '--- Test 1: Rohdaten in der Schnittstellentabelle ---';
-- Erwartet: 13 Zeilen. Elf gueltige mit zusammen 5000 MWh, dazu zwei
-- absichtlich fehlerhafte: PlantID 999 gibt es nicht, und DE-Grid-Coal-018
-- soll 9999 MWh liefern, mehr als seine Nennleistung.
SELECT * FROM Allocations;
GO

PRINT '--- Test 2: Import in ein freies Zeitfenster ---';
DECLARE @Uebernommen INT, @Abgelehnt INT, @TxID INT, @Fehler NVARCHAR(400);

EXEC dbo.spImportOptimizedResults
     @LineID           = 1,                          -- Leitung nach NL
     @DeliveryTimeSlot = '2026-08-22 07:00:00',      -- Zeitfenster ohne Vorbelegung
     @Uebernommen      = @Uebernommen OUTPUT,
     @Abgelehnt        = @Abgelehnt   OUTPUT,
     @TransactionID    = @TxID        OUTPUT,
     @Fehlermeldung    = @Fehler      OUTPUT;

SELECT @Uebernommen AS Uebernommen,     -- erwartet: 11
       @Abgelehnt   AS Abgelehnt,       -- erwartet: 2
       @TxID        AS TransaktionID,   -- erwartet: eine Nummer
       @Fehler      AS Fehlermeldung;   -- erwartet: NULL
GO

PRINT '--- Test 3: die Zuteilung kommt aus der Optimierung, nicht aus der Schaetzung ---';
-- Die Werte muessen exakt denen der Zwischentabelle entsprechen:
-- 583.35, 580.33, 570.92, 553.91, 473.25, 455.78, 424.78, 418.22, 383.06,
-- 330.16 und 226.24 MWh.
SELECT  Zuteilung.PlantID,
        Kraftwerk.PlantName,
        Zuteilung.AllocatedMWh
FROM TransactionPlantAllocations AS Zuteilung
INNER JOIN PowerPlants AS Kraftwerk ON Kraftwerk.PlantID = Zuteilung.PlantID
WHERE Zuteilung.TransactionID = (SELECT MAX(TransactionID) FROM Transactions)
ORDER BY Zuteilung.AllocatedMWh DESC;
GO

PRINT '--- Test 4: Begruendung der abgelehnten Zeilen ---';
SELECT TOP (10) SystemLogID, LogLevel, Message
FROM SystemLogs
WHERE Message LIKE 'Import%'
ORDER BY SystemLogID DESC;
-- Erwartet: eine INFO-Zeile zur Buchung und zwei WARNING-Zeilen mit
-- Kraftwerk 999 und Kraftwerk 18
GO

PRINT '--- Test 5: derselbe Import auf eine zu kleine Leitung ---';
DECLARE @U2 INT, @A2 INT, @T2 INT, @F2 NVARCHAR(400);

EXEC dbo.spImportOptimizedResults
     @LineID           = 2,                          -- Leitung nach AT, nur 600 MW
     @DeliveryTimeSlot = '2026-08-22 09:00:00',      -- freies Zeitfenster
     @Uebernommen      = @U2 OUTPUT,
     @Abgelehnt        = @A2 OUTPUT,
     @TransactionID    = @T2 OUTPUT,
     @Fehlermeldung    = @F2 OUTPUT;

SELECT @T2 AS TransaktionID,            -- erwartet: NULL
       @F2 AS Fehlermeldung;            -- erwartet: Stufe 1, benoetigt 5000, frei 600
GO

PRINT '--- Test 6: leere Schnittstellentabelle wird sauber abgefangen ---';
-- Nur ausfuehren, wenn du den Fall zeigen willst:
-- DELETE FROM dbo.Allocations;
-- DECLARE @U3 INT, @A3 INT, @T3 INT, @F3 NVARCHAR(400);
-- EXEC dbo.spImportOptimizedResults 1, '2026-08-22 10:00:00',
--      @U3 OUTPUT, @A3 OUTPUT, @T3 OUTPUT, @F3 OUTPUT;
-- SELECT @F3 AS Fehlermeldung;   -- erwartet: Hinweis auf die leere Tabelle
GO