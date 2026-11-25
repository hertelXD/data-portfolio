/*==============================================================================
  Projekt : GERDSS - German Energy Export Decision Support System
  Author  : Aileen Hertel
  Datei   : 004-002-spExecuteEnergyExport_Testskript.sql
  Zweck   : Testskript zur Prozedur spExecuteEnergyExport. Prueft den
            Erfolgsfall, beide Vorpruefungen und jede der drei Stufen einzeln.
  Technik : SELECT mit Testfaellen, EXEC mit OUTPUT-Parametern, PRINT

  Datenlage, auf die sich die Tests stuetzen (aus 001-006):
    Leitungen : 1 = NL 5000 MW, 2 = AT 600 MW, 3 = FR 3000 MW,
                4 = PL 2000 MW, 5 = CZ 1500 MW, 6 = DK 2500 MW
    Kredit    : NL 5 Mio, AT 3 Mio, FR 8 Mio, PL 4,5 Mio, CZ 3,5 Mio, DK 4 Mio
    Vertraege : NL 85,50 - AT 90,00 - FR 88,00 - PL 97,50
                CZ und DK ohne Vertrag, dort greift der Marktpreis
    Reserve   : 24 Stundenfenster am 22.08.2026, gesetzliches Minimum 500 MW
                Randstunden 2500 MW vorgehalten -> 2000 MW frei
                Mittag 10 bis 15 Uhr 1000 MW  -> 500 MW frei
    Erzeugung : 124 erneuerbare Anlagen mit zusammen 35.688 MW

  Voraussetzung: die Datenbank ist frisch aufgebaut. Wird das Skript ein
            zweites Mal ausgefuehrt, ohne die Buchungen zu loeschen, ist das
            Zeitfenster aus Test 1 bereits belegt und Test 1 schlaegt fehl.
            Zum Zuruecksetzen siehe den Block ganz unten.
==============================================================================*/

USE dbGERDSS;
GO

/*----------------------------------------------------------------------------
  TEST 1 - gueltige Buchung
  Leitung nach NL, Randstunde, 3000 von 5000 MWh.
  Stufe 1: 5000 frei              Stufe 2: 256.500 EUR gegen 5 Mio
  Stufe 3: 450 MW noetig, 2000 frei
----------------------------------------------------------------------------*/
PRINT '--- Test 1: erfolgreiche Buchung ueber die Leitung nach NL ---';
DECLARE @ID INT, @Fehler NVARCHAR(400);

EXEC dbo.spExecuteEnergyExport
     @LineID           = 1,
     @DeliveryTimeSlot = '2026-08-22T06:00:00',
     @TotalMWh         = 3000,
     @TransactionID    = @ID     OUTPUT,
     @Fehlermeldung    = @Fehler OUTPUT;

SELECT @ID AS TransactionID, @Fehler AS Fehlermeldung;
-- Erwartet: ID gefuellt, Fehlermeldung NULL

-- Belegte Kapazitaet der Leitung. Der Trigger dazu entsteht erst in 005-001,
-- vorher steht hier noch 0.00.
SELECT LineID, MaxCapacityMW, BookedMWh AS Belegt_nach_Buchung
FROM TransmissionLines WHERE LineID = 1;

-- Die m:n-Zuteilung wurde angelegt: die Menge verteilt sich im Verhaeltnis
-- der Nennleistung auf alle erneuerbaren Anlagen.
SELECT COUNT(*)                  AS AnzahlAnlagen,      -- erwartet: 124
       SUM(Zuteilung.AllocatedMWh) AS SummeMWh          -- erwartet: rund 3000
FROM TransactionPlantAllocations AS Zuteilung
WHERE Zuteilung.TransactionID = @ID;

SELECT TOP (10) Kraftwerk.PlantName, Zuteilung.AllocatedMWh
FROM TransactionPlantAllocations AS Zuteilung
INNER JOIN PowerPlants AS Kraftwerk ON Kraftwerk.PlantID = Zuteilung.PlantID
WHERE Zuteilung.TransactionID = @ID
ORDER BY Zuteilung.AllocatedMWh DESC;
GO

/*----------------------------------------------------------------------------
  TEST 2 - Vorpruefung: Leitung gibt es nicht
----------------------------------------------------------------------------*/
PRINT '--- Test 2: nicht vorhandene Leitung ---';
DECLARE @ID INT, @Fehler NVARCHAR(400);

EXEC dbo.spExecuteEnergyExport
     @LineID           = 99,
     @DeliveryTimeSlot = '2026-08-22T06:00:00',
     @TotalMWh         = 100,
     @TransactionID    = @ID     OUTPUT,
     @Fehlermeldung    = @Fehler OUTPUT;

SELECT @ID AS TransactionID, @Fehler AS Fehlermeldung;
-- Erwartet: ID NULL, "Die angegebene Leitung existiert nicht."
GO

/*----------------------------------------------------------------------------
  TEST 3 - Vorpruefung: negative Menge
----------------------------------------------------------------------------*/
PRINT '--- Test 3: negative Liefermenge ---';
DECLARE @ID INT, @Fehler NVARCHAR(400);

EXEC dbo.spExecuteEnergyExport
     @LineID           = 1,
     @DeliveryTimeSlot = '2026-08-22T06:00:00',
     @TotalMWh         = -500,
     @TransactionID    = @ID     OUTPUT,
     @Fehlermeldung    = @Fehler OUTPUT;

SELECT @ID AS TransactionID, @Fehler AS Fehlermeldung;
-- Erwartet: "Die Liefermenge muss groesser als null sein."
GO

/*----------------------------------------------------------------------------
  STUFE 1 - Kapazitaet der Leitung
----------------------------------------------------------------------------*/
PRINT '--- Test 4: Menge ueber der Leitungskapazitaet (AT, nur 600 MW) ---';
DECLARE @ID INT, @Fehler NVARCHAR(400);

EXEC dbo.spExecuteEnergyExport
     @LineID           = 2,
     @DeliveryTimeSlot = '2026-08-22T06:00:00',
     @TotalMWh         = 5000,
     @TransactionID    = @ID     OUTPUT,
     @Fehlermeldung    = @Fehler OUTPUT;

SELECT @ID AS TransactionID, @Fehler AS Fehlermeldung;
-- Erwartet: Stufe 1, benoetigt 5000 MWh, frei nur 600
GO

PRINT '--- Test 5: Zeitfenster bereits belegt (NL, dieselbe Stunde wie Test 1) ---';
DECLARE @ID INT, @Fehler NVARCHAR(400);

EXEC dbo.spExecuteEnergyExport
     @LineID           = 1,
     @DeliveryTimeSlot = '2026-08-22T06:00:00',
     @TotalMWh         = 3000,
     @TransactionID    = @ID     OUTPUT,
     @Fehlermeldung    = @Fehler OUTPUT;

SELECT @ID AS TransactionID, @Fehler AS Fehlermeldung;
-- Erwartet: Stufe 1, frei sind nur noch 2000 MWh
GO

/*----------------------------------------------------------------------------
  STUFE 2 - Kreditrahmen des Ziellandes
  Tschechien hat 3,5 Mio Rahmen. 1500 MWh zu 3000 EUR ergeben 4,5 Mio.
  Der Preis wird ausdruecklich vorgegeben, weil CZ keinen Vertrag hat.
----------------------------------------------------------------------------*/
PRINT '--- Test 6: Auftragswert ueber dem Kreditrahmen (CZ) ---';
DECLARE @ID INT, @Fehler NVARCHAR(400);

EXEC dbo.spExecuteEnergyExport
     @LineID           = 5,
     @DeliveryTimeSlot = '2026-08-22T06:00:00',
     @TotalMWh         = 1500,
     @PricePerMWh      = 3000.00,
     @TransactionID    = @ID     OUTPUT,
     @Fehlermeldung    = @Fehler OUTPUT;

SELECT @ID AS TransactionID, @Fehler AS Fehlermeldung;
-- Erwartet: Stufe 2 mit Auftragswert und freiem Rahmen
GO

/*----------------------------------------------------------------------------
  STUFE 3 - Netzstabilitaet
  Mittags sind nur 500 MW Reserve frei. 5000 MWh Export erfordern
  750 MW Zusatzreserve.
----------------------------------------------------------------------------*/
PRINT '--- Test 7: Netzstabilitaet verletzt (NL um 12:00) ---';
DECLARE @ID INT, @Fehler NVARCHAR(400);

EXEC dbo.spExecuteEnergyExport
     @LineID           = 1,
     @DeliveryTimeSlot = '2026-08-22T12:00:00',
     @TotalMWh         = 5000,
     @TransactionID    = @ID     OUTPUT,
     @Fehlermeldung    = @Fehler OUTPUT;

SELECT @ID AS TransactionID, @Fehler AS Fehlermeldung;
-- Erwartet: Stufe 3 mit Export, Zusatzreserve und freier Reserve
GO

/*----------------------------------------------------------------------------
  TEST 8 - alle Ablehnungen wurden protokolliert
----------------------------------------------------------------------------*/
PRINT '--- Test 8: Protokoll der Ablehnungen ---';
SELECT TOP (10) SystemLogID, LogLevel, Message, CreatedAt
FROM SystemLogs
WHERE LogLevel = 'ERROR'
ORDER BY SystemLogID DESC;
-- Erwartet: sechs Eintraege aus den Tests 2 bis 7
GO

/*----------------------------------------------------------------------------
  ZURUECKSETZEN - nur ausfuehren, wenn das Skript erneut laufen soll
  Loescht alle Buchungen und Protokolle, laesst die Stammdaten unberuehrt.
----------------------------------------------------------------------------*/
-- DELETE FROM TransactionPlantAllocations;
-- DELETE FROM GridBalanceLogs;
-- DELETE FROM Transactions;
-- UPDATE TransmissionLines SET BookedMWh = 0.00;
-- DELETE FROM SystemLogs;
-- GO
