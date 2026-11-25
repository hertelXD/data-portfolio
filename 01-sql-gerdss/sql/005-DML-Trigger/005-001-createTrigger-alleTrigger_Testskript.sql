/*==============================================================================
  Projekt : GERDSS - German Energy Export Decision Support System
  Author  : Aileen Hertel
  Datei   : 005-001-createTrigger-alleTrigger_Testskript.sql
  Zweck   : Testskript zu allen fuenf Triggern. Jeder Abschnitt loest den
            Trigger aus und zeigt die Wirkung im Protokoll.
  Technik : SELECT mit Testfaellen, EXEC mit OUTPUT-Parametern, INSERT, UPDATE,
            TRY...CATCH, PRINT

  Voraussetzung: 004-002 ist angelegt und die Stammdaten sind geladen. Alle
            Buchungen laufen ueber die Leitung nach Daenemark (Leitung 6,
            2500 MW) am 22.08.2026 - dem Tag, fuer den Marktpreise und
            Reservefahrplaene hinterlegt sind. Daenemark hat keinen
            Rahmenvertrag, der Preis kommt daher aus MarketPrices.

  Vor einem erneuten Lauf die Buchungen zuruecksetzen, siehe Block am Ende.
==============================================================================*/

USE dbGERDSS;
GO

SET ANSI_NULLS ON;                                           -- ISO-Standard fuer NULL-Vergleiche
GO

SET QUOTED_IDENTIFIER ON;                                    -- Erlaubt doppelt gesetzte Bezeichner
GO

/*------------------------------------------------------------------------------
  1. trUpdateGridBalance - schreibt die belegte Kapazitaet fort und protokolliert
------------------------------------------------------------------------------*/
PRINT '--- Ausgangslage merken ---';
SELECT LineID, BookedMWh AS Belegt_vorher FROM TransmissionLines WHERE LineID = 6;
SELECT COUNT(*) AS Protokollzeilen_vorher FROM GridBalanceLogs;
GO

PRINT '--- Buchung ausloesen (DK, 17:00, 500 MWh) ---';
DECLARE @ID INT, @Fehler NVARCHAR(400);

EXEC dbo.spExecuteEnergyExport
     @LineID           = 6,
     @DeliveryTimeSlot = '2026-08-22T17:00:00',
     @TotalMWh         = 500,
     @TransactionID    = @ID     OUTPUT,
     @Fehlermeldung    = @Fehler OUTPUT;

SELECT @ID AS Neue_TransactionID, @Fehler AS Fehlermeldung;
-- Erwartet: ID gefuellt, Fehlermeldung NULL
GO

PRINT '--- Wirkung des Triggers pruefen ---';
-- 1. Die belegte Kapazitaet wurde um 500 erhoeht
SELECT LineID, BookedMWh AS Belegt_nachher FROM TransmissionLines WHERE LineID = 6;
-- Erwartet: 500.00

-- 2. Es gibt eine neue Protokollzeile zum Netzzustand
SELECT TOP (1) LogID, TransactionID, PostTransactionBalanceMW, LoggedAt
FROM GridBalanceLogs ORDER BY LogID DESC;

-- 3. Es gibt einen Eintrag im Systemprotokoll, mit Verlustangabe aus der Funktion
SELECT TOP (1) SystemLogID, LogLevel, Message
FROM SystemLogs WHERE LogLevel = 'INFO' ORDER BY SystemLogID DESC;
GO

PRINT '--- Belegung aller Leitungen im Ueberblick ---';
-- Der Trigger gruppiert nach LineID und kommt deshalb auch mit mehreren
-- Zeilen in einem Vorgang zurecht.
SELECT Leitung.LineID, Leitung.BookedMWh
FROM TransmissionLines AS Leitung
ORDER BY Leitung.LineID;
GO

/*------------------------------------------------------------------------------
  2. trReleaseCapacityOnCancel - gibt die Kapazitaet bei Stornierung frei
------------------------------------------------------------------------------*/
PRINT '--- Test 1: zweite Buchung anlegen (DK, 18:00, 400 MWh) ---';
DECLARE @ID INT, @Fehler NVARCHAR(400);

EXEC dbo.spExecuteEnergyExport
     @LineID           = 6,
     @DeliveryTimeSlot = '2026-08-22T18:00:00',
     @TotalMWh         = 400,
     @TransactionID    = @ID     OUTPUT,
     @Fehlermeldung    = @Fehler OUTPUT;

SELECT @ID AS Neue_TransactionID, @Fehler AS Fehlermeldung;
SELECT LineID, BookedMWh AS Belegt_nach_Buchung
FROM TransmissionLines WHERE LineID = 6;
-- Erwartet: 900.00 (500 aus Abschnitt 1 plus 400)
GO

PRINT '--- Test 2: Stornieren, Kapazitaet muss zurueckgehen ---';
DECLARE @ID INT = (SELECT MAX(TransactionID) FROM Transactions WHERE Status = 'Gebucht');
DECLARE @Line INT = (SELECT LineID FROM Transactions WHERE TransactionID = @ID);

UPDATE Transactions SET Status = 'Storniert' WHERE TransactionID = @ID;

SELECT LineID, BookedMWh AS Belegt_nach_Storno
FROM TransmissionLines WHERE LineID = @Line;
-- Erwartet: 500.00, die 400 sind wieder frei

SELECT TOP (1) SystemLogID, LogLevel, Message
FROM SystemLogs WHERE LogLevel = 'WARNING' ORDER BY SystemLogID DESC;
-- Erwartet: Eintrag mit der freigegebenen Menge
GO

PRINT '--- Test 3: erneutes Speichern desselben Status loest nichts aus ---';
DECLARE @Vorher INT = (SELECT COUNT(*) FROM SystemLogs);
DECLARE @ID INT = (SELECT MAX(TransactionID) FROM Transactions WHERE Status = 'Storniert');

UPDATE Transactions SET Status = 'Storniert' WHERE TransactionID = @ID;

SELECT @Vorher AS Protokollzeilen_vorher,
       (SELECT COUNT(*) FROM SystemLogs) AS Protokollzeilen_nachher;
-- Erwartet: beide Zahlen gleich, weil kein echter Statuswechsel stattfand
GO

PRINT '--- Test 4: ungueltiger Status wird von der Einschraenkung abgewiesen ---';
BEGIN TRY
    UPDATE TOP (1) Transactions SET Status = 'Irgendwas';
    PRINT 'FEHLER: Der Wert wurde angenommen.';
END TRY
BEGIN CATCH
    PRINT 'OK - abgelehnt: ' + ERROR_MESSAGE();
END CATCH
GO

/*------------------------------------------------------------------------------
  3. trLogPlantAllocation - warnt bei abweichender Zuteilungssumme
------------------------------------------------------------------------------*/
PRINT '--- Test 1: korrekte Zuteilung erzeugt keine Warnung ---';
SELECT  Lieferung.TransactionID,
        Lieferung.TotalMWh,
        SUM(Zuteilung.AllocatedMWh)                           AS Zugeteilt,
        ABS(Lieferung.TotalMWh - SUM(Zuteilung.AllocatedMWh)) AS Abweichung
FROM Transactions AS Lieferung
INNER JOIN TransactionPlantAllocations AS Zuteilung ON Zuteilung.TransactionID = Lieferung.TransactionID
GROUP BY Lieferung.TransactionID, Lieferung.TotalMWh
ORDER BY Abweichung DESC;
-- Erwartet: die Abweichung liegt unter 1 MWh (Rundung auf 124 Anlagen)
GO

PRINT '--- Test 2: fehlerhafte Zuteilung loest die Warnung aus ---';
DECLARE @T INT = (SELECT MIN(TransactionID) FROM Transactions);
-- Ein fossiles Kraftwerk, das an der Verteilung nicht beteiligt war
DECLARE @P INT = (SELECT MIN(Kraftwerk.PlantID)
                  FROM PowerPlants AS Kraftwerk
                  INNER JOIN PowerPlantTypes AS Technologie ON Technologie.PlantTypeID = Kraftwerk.PlantTypeID
                  WHERE Technologie.IsRenewable = 0);

-- Zusatzmenge deutlich ueber der Rundungstoleranz von 1 MWh
INSERT INTO TransactionPlantAllocations (TransactionID, PlantID, AllocatedMWh)
VALUES (@T, @P, 50.00);

SELECT TOP (1) SystemLogID, LogLevel, Message
FROM SystemLogs WHERE LogLevel = 'WARNING' ORDER BY SystemLogID DESC;
-- Erwartet: Warnung mit Soll- und Istmenge

-- Testdatensatz wieder entfernen
DELETE FROM TransactionPlantAllocations
WHERE TransactionID = @T AND PlantID = @P AND AllocatedMWh = 50.00;
GO

/*------------------------------------------------------------------------------
  4. trPreventReserveOverlap - verhindert ueberlappende Zeitfenster
------------------------------------------------------------------------------*/
PRINT '--- Ausgangslage: die ersten Fahrplaene ---';
SELECT TOP (5) ScheduleID, StartTime, EndTime, AvailableReserveMW, RequiredReserveMW
FROM ReserveSchedules
ORDER BY StartTime;
GO

PRINT '--- Test 1: ueberlappendes Zeitfenster muss abgelehnt werden ---';
BEGIN TRY
    -- 10:30 bis 11:30 liegt mitten in zwei bestehenden Stundenbloecken
    INSERT INTO ReserveSchedules (StartTime, EndTime, AvailableReserveMW, RequiredReserveMW)
    VALUES ('2026-08-22T10:30:00', '2026-08-22T11:30:00', 3000.00, 2000.00);
    PRINT 'FEHLER: Der Datensatz wurde angenommen.';
END TRY
BEGIN CATCH
    PRINT 'OK - abgelehnt: ' + ERROR_MESSAGE();
END CATCH
GO

PRINT '--- Test 2: freies Anschlussfenster muss angenommen werden ---';
BEGIN TRY
    -- der Folgetag ist frei, es gibt keine Ueberschneidung
    INSERT INTO ReserveSchedules (StartTime, EndTime, AvailableReserveMW, RequiredReserveMW)
    VALUES ('2026-08-23T00:00:00', '2026-08-23T04:00:00', 3600.00, 2000.00);
    PRINT 'OK - angenommen (Vierstundenblock, keine Ueberlappung).';
END TRY
BEGIN CATCH
    PRINT 'FEHLER: ' + ERROR_MESSAGE();
END CATCH
GO

PRINT '--- Test 3: Ende vor Beginn muss die CHECK-Einschraenkung abfangen ---';
BEGIN TRY
    INSERT INTO ReserveSchedules (StartTime, EndTime, AvailableReserveMW, RequiredReserveMW)
    VALUES ('2026-08-24T10:00:00', '2026-08-24T08:00:00', 3000.00, 2000.00);
    PRINT 'FEHLER: Der Datensatz wurde angenommen.';
END TRY
BEGIN CATCH
    PRINT 'OK - abgelehnt: ' + ERROR_MESSAGE();
END CATCH
GO

PRINT '--- Aufraeumen: Testblock aus Test 2 entfernen ---';
DELETE FROM ReserveSchedules WHERE StartTime = '2026-08-23T00:00:00';
GO

SELECT COUNT(*) AS AnzahlFahrplaene FROM ReserveSchedules;    -- erwartet: 24
GO

/*------------------------------------------------------------------------------
  5. trAuditExportContracts - protokolliert Anlage und Preisaenderung
------------------------------------------------------------------------------*/
PRINT '--- Test 1: Neuanlage wird protokolliert ---';
INSERT INTO ExportContracts (ExporterCountryID, ImporterCountryID,
                             ContractStartDate, ContractEndDate, AgreedPricePerMWh)
VALUES (1, 2, '2026-09-01 00:00:00', '2026-12-31 23:59:59', 80.00);

DECLARE @TestVertrag INT = SCOPE_IDENTITY();

SELECT 'Test 1 - Neuanlage' AS Test, ActionType, ChangedBy, Details
FROM ContractAuditLogs
WHERE ContractID = @TestVertrag;                    -- erwartet: eine Zeile, INSERT

PRINT '--- Test 2: Preisaenderung wird protokolliert ---';
UPDATE ExportContracts
SET AgreedPricePerMWh = 95.00
WHERE ContractID = @TestVertrag;

SELECT 'Test 2 - Preisaenderung' AS Test, ActionType, Details
FROM ContractAuditLogs
WHERE ContractID = @TestVertrag AND ActionType = 'UPDATE';   -- erwartet: eine Zeile

PRINT '--- Test 3: Aenderung ohne Preis wird nicht protokolliert ---';
UPDATE ExportContracts
SET ContractEndDate = '2027-01-31 23:59:59'
WHERE ContractID = @TestVertrag;

SELECT 'Test 3 - nur Frist' AS Test, COUNT(*) AS AnzahlUpdateEintraege
FROM ContractAuditLogs
WHERE ContractID = @TestVertrag AND ActionType = 'UPDATE';   -- erwartet: weiterhin 1

PRINT '--- Aufraeumen ---';
DELETE FROM ContractAuditLogs WHERE ContractID = @TestVertrag;
DELETE FROM ExportContracts   WHERE ContractID = @TestVertrag;
GO

/*------------------------------------------------------------------------------
  ZURUECKSETZEN - nur ausfuehren, wenn das Skript erneut laufen soll
------------------------------------------------------------------------------*/
-- DELETE FROM TransactionPlantAllocations;
-- DELETE FROM GridBalanceLogs;
-- DELETE FROM Transactions;
-- UPDATE TransmissionLines SET BookedMWh = 0.00;
-- DELETE FROM SystemLogs;
-- DELETE FROM ContractAuditLogs;
-- DELETE FROM ReserveSchedules WHERE StartTime >= '2026-08-23';
-- GO
