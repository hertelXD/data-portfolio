/*==============================================================================
  Projekt : GERDSS - German Energy Export Decision Support System
  Author  : Aileen Hertel
  Datei   : 003-001-createFunction-alleFunktionen_Testskript.sql
  Zweck   : Testskript zu allen fuenf Funktionen. Jeder Abschnitt prueft eine
            Funktion mit gueltigen und mit ungueltigen Eingaben.
  Technik : SELECT mit Testfaellen, PRINT, Aufruf skalarer Funktionen in der
            Spaltenliste, CROSS APPLY fuer die Tabellenwertfunktion

  Hinweis : Voraussetzung: 001-006 (Stammdaten) ist gelaufen.
==============================================================================*/

USE dbGERDSS;
GO

SET ANSI_NULLS ON;                                           -- ISO-Standard fuer NULL-Vergleiche
GO

SET QUOTED_IDENTIFIER ON;                                    -- Erlaubt doppelt gesetzte Bezeichner
GO

/*------------------------------------------------------------------------------
  1. sfCalculateNetPower
------------------------------------------------------------------------------*/
PRINT '--- Test 1: Normalfall, 1000 MW bei 2,5 Prozent Verlust ---';
SELECT dbo.sfCalculateNetPower(1000.00, 2.50) AS Erwartet_975;
GO

PRINT '--- Test 2: kein Verlust ---';
SELECT dbo.sfCalculateNetPower(500.00, 0.00) AS Erwartet_500;
GO

PRINT '--- Test 3: Randfaelle, muessen 0 liefern ---';
SELECT  dbo.sfCalculateNetPower(NULL, 2.50)   AS BruttoNULL,
        dbo.sfCalculateNetPower(1000.00, NULL) AS VerlustNULL,
        dbo.sfCalculateNetPower(0.00, 2.50)    AS BruttoNull,
        dbo.sfCalculateNetPower(-100.00, 2.50) AS BruttoNegativ;
GO

PRINT '--- Test 4: auf alle Leitungen angewandt ---';
SELECT  Leitung.LineID,
        Leitung.MaxCapacityMW                                              AS BruttoMW,
        Leitung.LossPercentage                                             AS VerlustProzent,
        dbo.sfCalculateNetPower(Leitung.MaxCapacityMW, Leitung.LossPercentage) AS NettoMW,
        Leitung.MaxCapacityMW - dbo.sfCalculateNetPower(Leitung.MaxCapacityMW, Leitung.LossPercentage) AS VerlustMW
FROM TransmissionLines AS Leitung
ORDER BY Leitung.LineID;
GO

/*------------------------------------------------------------------------------
  2. sfCalculateTransmissionLoss
------------------------------------------------------------------------------*/
PRINT '--- Test 1: Verlust je Leitung bei 1000 MWh ---';
SELECT  Leitung.LineID,
        ZielKnoten.NodeName                                            AS NachKnoten,
        Leitung.LossPercentage                                      AS Verlustanteil,
        dbo.sfCalculateTransmissionLoss(1000, Leitung.LineID)       AS Verlust_MWh
FROM TransmissionLines AS Leitung
INNER JOIN GridNodes AS ZielKnoten ON ZielKnoten.NodeID = Leitung.ToNodeID
ORDER BY Verlust_MWh DESC;
-- Erwartet: der Verlust entspricht genau dem Prozentsatz der Leitung.
-- Beispiel Leitung nach Italien, 4,14 % -> 41,400 MWh

PRINT '--- Test 2: unbekannte Leitung muss NULL liefern ---';
SELECT dbo.sfCalculateTransmissionLoss(1000, 9999) AS Ergebnis_erwartet_NULL;

PRINT '--- Test 3: fehlende Menge muss NULL liefern ---';
SELECT dbo.sfCalculateTransmissionLoss(NULL, 1) AS Ergebnis_erwartet_NULL;

PRINT '--- Test 4: Einsatz in einer Auswertung ueber alle Lieferungen ---';
SELECT  Lieferung.TransactionID,
        Lieferung.TotalMWh,
        dbo.sfCalculateTransmissionLoss(Lieferung.TotalMWh, Lieferung.LineID) AS Verlust_MWh,
        Lieferung.TotalMWh - dbo.sfCalculateTransmissionLoss(Lieferung.TotalMWh, Lieferung.LineID) AS Netto_MWh
FROM Transactions AS Lieferung
ORDER BY Lieferung.TransactionID;
GO

/*------------------------------------------------------------------------------
  3. sfGetAvailableCapacity
------------------------------------------------------------------------------*/
PRINT '--- Test 1: freie Kapazitaet aller Leitungen um 09:00 Uhr ---';
SELECT  Leitung.LineID,
        ZielKnoten.NodeName                                                     AS NachKnoten,
        Leitung.MaxCapacityMW,
        Leitung.IsActive,
        dbo.sfGetAvailableCapacity(Leitung.LineID, '2026-08-22T09:00:00')    AS Frei_MWh
FROM TransmissionLines AS Leitung
INNER JOIN GridNodes AS ZielKnoten ON ZielKnoten.NodeID = Leitung.ToNodeID
ORDER BY Leitung.LineID;
-- Erwartet: die Leitung in die Schweiz liefert 0, weil sie ausser Betrieb ist.
-- Auf den Leitungen nach NL und FR ist um 09:00 bereits etwas gebucht.

PRINT '--- Test 2: derselbe Zeitpunkt eine Stunde spaeter ---';
SELECT  Leitung.LineID,
        dbo.sfGetAvailableCapacity(Leitung.LineID, '2026-08-22T14:00:00') AS Frei_MWh
FROM TransmissionLines AS Leitung
ORDER BY Leitung.LineID;
-- Erwartet: volle Kapazitaet, weil in diesem Slot noch nichts gebucht ist.

PRINT '--- Test 3: unbekannte Leitung muss 0 liefern ---';
SELECT dbo.sfGetAvailableCapacity(9999, '2026-08-22T09:00:00') AS Ergebnis_erwartet_0;
GO

/*------------------------------------------------------------------------------
  4. sfCalculateCO2Emission
------------------------------------------------------------------------------*/
PRINT '--- Test 1: Emission je Technologie bei 100 MWh ---';
-- Je Technologie ein Beispielkraftwerk, sonst waeren es 150 Zeilen.
SELECT  Technologie.TypeName,
        Technologie.CO2EmissionFactor,
        Technologie.IsRenewable,
        MIN(Kraftwerk.PlantName) AS Beispielkraftwerk,
        dbo.sfCalculateCO2Emission(100, MIN(Kraftwerk.PlantID)) AS Emission_Tonnen
FROM PowerPlants AS Kraftwerk
INNER JOIN PowerPlantTypes AS Technologie ON Technologie.PlantTypeID = Kraftwerk.PlantTypeID
GROUP BY Technologie.TypeName, Technologie.CO2EmissionFactor, Technologie.IsRenewable
ORDER BY Emission_Tonnen DESC;
-- Erwartet: Coal 85,000 - Gas 38,000 - Solar 4,800 - Hydro 2,400
--           WindOffshore 1,200 - WindOnshore 1,100 Tonnen

PRINT '--- Test 2: tatsaechliche Emission je Lieferung ---';
SELECT TOP (20)
        Zuteilung.TransactionID,
        Kraftwerk.PlantName,
        Zuteilung.AllocatedMWh,
        dbo.sfCalculateCO2Emission(Zuteilung.AllocatedMWh, Zuteilung.PlantID) AS Emission_Tonnen
FROM TransactionPlantAllocations AS Zuteilung
INNER JOIN PowerPlants AS Kraftwerk ON Kraftwerk.PlantID = Zuteilung.PlantID
ORDER BY Zuteilung.AllocatedMWh DESC;
-- Ohne Buchung bleibt das Ergebnis leer. Es fuellt sich nach 004-002.

PRINT '--- Test 3: unbekanntes Kraftwerk muss NULL liefern ---';
SELECT dbo.sfCalculateCO2Emission(100, 9999) AS Ergebnis_erwartet_NULL;
GO

/*------------------------------------------------------------------------------
  5. tfGetRoutesInRadius
------------------------------------------------------------------------------*/
PRINT '--- Test 1: enger Radius, 100 km ---';
SELECT * FROM dbo.tfGetRoutesInRadius(100.00);              -- erwartet: wenige oder keine Zeilen
GO

PRINT '--- Test 2: weiter Radius, 500 km ---';
SELECT * FROM dbo.tfGetRoutesInRadius(500.00);              -- erwartet: mehr Zeilen als in Test 1
GO

PRINT '--- Test 3: Radius 0, muss leer bleiben ---';
SELECT COUNT(*) AS AnzahlZeilen FROM dbo.tfGetRoutesInRadius(0.00);   -- erwartet: 0
GO

PRINT '--- Test 4: Verwendung in einer Abfrage ---';
SELECT  Route.Zielland,
        COUNT(*)          AS AnzahlLeitungen,
        SUM(Route.MaxCapacityMW) AS SummeKapazitaetMW
FROM dbo.tfGetRoutesInRadius(500.00) AS Route
GROUP BY Route.Zielland
ORDER BY SummeKapazitaetMW DESC;
GO
