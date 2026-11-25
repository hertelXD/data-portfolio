/*==============================================================================
  Projekt : GERDSS - German Energy Export Decision Support System
  Author  : Aileen Hertel
  Datei   : 004-003-spImportOptimizedResults.sql
  Zweck   : Uebernimmt das Ergebnis der externen Optimierung. Die Python-Schicht
            liefert je Kraftwerk eine zugeteilte Menge - sie sagt also, WOMIT
            geliefert wird, aber nicht WOHIN und WANN. Ziel und Zeitfenster
            kommen deshalb als Parameter herein.

            Ablauf:
              1. jede Staging-Zeile einzeln pruefen (Kraftwerk bekannt, Menge
                 positiv, Menge nicht groesser als die Nennleistung)
              2. die gueltigen Mengen aufsummieren
              3. die Summe ueber spExecuteEnergyExport buchen - damit laufen
                 auch importierte Daten durch alle drei Pruefstufen
              4. die Zuteilung je Kraftwerk aus der Optimierung eintragen,
                 statt sie proportional zu schaetzen
  Technik : CREATE PROCEDURE mit Eingangs- und OUTPUT-Parametern, CURSOR mit
            FETCH-Schleife, TRY_CAST zur Pruefung der Rohdaten, Tabellenvariable,
            EXEC einer eigenen Prozedur, INSERT ... SELECT, TRY...CATCH

  Voraussetzung: 007-002 hat die Stagingtabelle angelegt und gefuellt.
==============================================================================*/

USE dbGERDSS;
GO

CREATE OR ALTER PROCEDURE dbo.spImportOptimizedResults
(
    @LineID             INT,                            -- Eingang: Ziel-Leitung
    @DeliveryTimeSlot   DATETIME2(0),                   -- Eingang: Lieferzeitfenster
    @Uebernommen        INT             OUTPUT,         -- Ausgang: verwertete Zeilen
    @Abgelehnt          INT             OUTPUT,         -- Ausgang: verworfene Zeilen
    @TransactionID      INT             OUTPUT,         -- Ausgang: neue Buchung oder NULL
    @Fehlermeldung      NVARCHAR(400)   OUTPUT          -- Ausgang: Grund, falls nicht gebucht
)
AS
BEGIN
    SET NOCOUNT ON;

    SET @Uebernommen   = 0;
    SET @Abgelehnt     = 0;
    SET @TransactionID = NULL;
    SET @Fehlermeldung = NULL;

/*----------------------------------------------------------------------------
  VORPRUEFUNG
----------------------------------------------------------------------------*/
    IF OBJECT_ID('dbo.Allocations') IS NULL
    BEGIN
        SET @Fehlermeldung = N'Stagingtabelle fehlt. Zuerst 007-002 ausfuehren.';
        INSERT INTO SystemLogs (LogLevel, Message) VALUES ('WARNING', @Fehlermeldung);
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.Allocations)
    BEGIN
        SET @Fehlermeldung = N'Die Stagingtabelle ist leer.';
        INSERT INTO SystemLogs (LogLevel, Message) VALUES ('WARNING', @Fehlermeldung);
        RETURN;
    END

/*----------------------------------------------------------------------------
  SCHRITT 1 - Zeilen einzeln pruefen
  Gueltige Zeilen sammeln, abgelehnte mit Begruendung protokollieren.
----------------------------------------------------------------------------*/
    DECLARE @Gueltig TABLE
    (
        PlantID         INT             NOT NULL,
        AllocatedMWh    DECIMAL(10,2)   NOT NULL
    );

    DECLARE @PlantID    INT;
    DECLARE @PlantName  NVARCHAR(120);
    DECLARE @MWh        DECIMAL(10,2);
    DECLARE @Kapazitaet DECIMAL(10,2);
    DECLARE @Grund      NVARCHAR(400);

    DECLARE Zeilen CURSOR LOCAL FAST_FORWARD FOR
        SELECT  TRY_CAST(PlantID      AS INT),
                PlantName,
                TRY_CAST(AllocatedMWh AS DECIMAL(10,2))
        FROM dbo.Allocations;

    OPEN Zeilen;
    FETCH NEXT FROM Zeilen INTO @PlantID, @PlantName, @MWh;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Grund      = NULL;
        SET @Kapazitaet = NULL;

        SELECT @Kapazitaet = Kraftwerk.MaxCapacityMW
        FROM PowerPlants AS Kraftwerk
        WHERE Kraftwerk.PlantID = @PlantID;

        IF @PlantID IS NULL OR @MWh IS NULL
            SET @Grund = N'Zeile nicht lesbar: PlantID oder AllocatedMWh ist keine Zahl.';
        ELSE IF @Kapazitaet IS NULL
            SET @Grund = CONCAT(N'Kraftwerk ', @PlantID, N' ist nicht bekannt.');
        ELSE IF @MWh < 0
            SET @Grund = CONCAT(N'Kraftwerk ', @PlantID, N': negative Menge.');
        ELSE IF @MWh > @Kapazitaet
            SET @Grund = CONCAT(N'Kraftwerk ', @PlantID, N': ', @MWh,
                                N' MWh uebersteigen die Nennleistung von ', @Kapazitaet, N' MW.');

        IF @Grund IS NOT NULL
        BEGIN
            SET @Abgelehnt = @Abgelehnt + 1;
            INSERT INTO SystemLogs (LogLevel, Message)
            VALUES ('WARNING', CONCAT(N'Import abgelehnt: ', @Grund));
        END
        ELSE IF @MWh > 0                -- Zeilen mit 0 MWh sind gueltig, aber wirkungslos
        BEGIN
            INSERT INTO @Gueltig (PlantID, AllocatedMWh) VALUES (@PlantID, @MWh);
            SET @Uebernommen = @Uebernommen + 1;
        END

        FETCH NEXT FROM Zeilen INTO @PlantID, @PlantName, @MWh;
    END

    CLOSE Zeilen;
    DEALLOCATE Zeilen;

/*----------------------------------------------------------------------------
  SCHRITT 2 - Gesamtmenge bilden
----------------------------------------------------------------------------*/
    DECLARE @Gesamt DECIMAL(12,2) = (SELECT ISNULL(SUM(AllocatedMWh), 0) FROM @Gueltig);

    IF @Gesamt <= 0
    BEGIN
        SET @Fehlermeldung = N'Keine verwertbare Zeile im Import. Es wurde nichts gebucht.';
        INSERT INTO SystemLogs (LogLevel, Message) VALUES ('WARNING', @Fehlermeldung);
        RETURN;
    END

/*----------------------------------------------------------------------------
  SCHRITT 3 - Buchung ueber die Pruefprozedur
  @VerteilungExtern = 1: die Prozedur verteilt nicht selbst, weil die
  Zuteilung aus der Optimierung kommt.
----------------------------------------------------------------------------*/
    BEGIN TRY
        EXEC dbo.spExecuteEnergyExport
             @LineID            = @LineID,
             @DeliveryTimeSlot  = @DeliveryTimeSlot,
             @TotalMWh          = @Gesamt,
             @VerteilungExtern  = 1,
             @TransactionID     = @TransactionID OUTPUT,
             @Fehlermeldung     = @Fehlermeldung OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Fehlermeldung = ERROR_MESSAGE();
        SET @TransactionID = NULL;
    END CATCH

    IF @TransactionID IS NULL
    BEGIN
        INSERT INTO SystemLogs (LogLevel, Message)
        VALUES ('WARNING', CONCAT(N'Import nicht gebucht: ', ISNULL(@Fehlermeldung, N'unbekannter Grund')));
        RETURN;
    END

/*----------------------------------------------------------------------------
  SCHRITT 4 - Zuteilung je Kraftwerk eintragen
  Hier steckt der Gewinn des Imports: die Verteilung kommt aus der
  Optimierung, nicht aus einer proportionalen Schaetzung.
----------------------------------------------------------------------------*/
    INSERT INTO TransactionPlantAllocations (TransactionID, PlantID, AllocatedMWh)
    SELECT @TransactionID, GueltigeZeile.PlantID, SUM(GueltigeZeile.AllocatedMWh)
    FROM @Gueltig AS GueltigeZeile
    GROUP BY GueltigeZeile.PlantID;              -- falls ein Kraftwerk mehrfach vorkommt

    INSERT INTO SystemLogs (LogLevel, Message)
    VALUES ('INFO', CONCAT(N'Import gebucht: Transaktion ', @TransactionID,
                           N', ', @Uebernommen, N' Kraftwerke, ', @Gesamt,
                           N' MWh gesamt, ', @Abgelehnt, N' Zeilen abgelehnt.'));
END
GO

/*---------------- Kontrolle: sechs Parameter, vier davon Ausgang ----------------*/
SELECT  Parameter.name         AS Parameter,
        Datentyp.name          AS Datentyp,
        Parameter.is_output    AS IstAusgang
FROM sys.procedures AS Prozedur
INNER JOIN sys.parameters AS Parameter ON Parameter.object_id    = Prozedur.object_id
INNER JOIN sys.types      AS Datentyp  ON Datentyp.user_type_id  = Parameter.user_type_id
WHERE Prozedur.name = 'spImportOptimizedResults'
ORDER BY Parameter.parameter_id;
GO
