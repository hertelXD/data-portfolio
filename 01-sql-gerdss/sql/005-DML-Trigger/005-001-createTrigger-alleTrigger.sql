/*==============================================================================
  Projekt : GERDSS - German Energy Export Decision Support System
  Author  : Aileen Hertel
  Datei   : 005-001-createTrigger-alleTrigger.sql
  Zweck   : Alle fuenf DML-Trigger in einem Skript. Zwei davon automatisieren
            Geschaeftsprozesse (Kapazitaet fortschreiben und freigeben), drei
            sichern Plausibilitaet und Nachvollziehbarkeit.
  Technik : CREATE OR ALTER TRIGGER, AFTER INSERT / UPDATE, Pseudotabellen
            inserted und deleted, UPDATE()-Praedikat, UPDATE mit Verknuepfung,
            INSERT ... SELECT, CROSS APPLY, RAISERROR mit ROLLBACK,
            Aufruf einer eigenen Skalarwertfunktion
==============================================================================*/

USE dbGERDSS;
GO

SET ANSI_NULLS ON;                                           -- ISO-Standard fuer NULL-Vergleiche
GO

SET QUOTED_IDENTIFIER ON;                                    -- Erlaubt doppelt gesetzte Bezeichner
GO

/*------------------------------------------------------------------------------
  1. trUpdateGridBalance - Transactions, AFTER INSERT: schreibt BookedMWh fort, protokolliert Netzzustand und Ereignis
------------------------------------------------------------------------------*/
CREATE OR ALTER TRIGGER trUpdateGridBalance
ON Transactions
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM inserted)
        RETURN;

    -- --- 1. belegte Kapazitaet je Leitung fortschreiben ---
    -- Gruppierung, weil ein INSERT mehrere Zeilen enthalten kann
    UPDATE Leitung
    SET Leitung.BookedMWh = Leitung.BookedMWh + Summe.Menge
    FROM TransmissionLines AS Leitung
    INNER JOIN (
        SELECT LineID, SUM(TotalMWh) AS Menge
        FROM inserted
        WHERE Status <> 'Storniert'
        GROUP BY LineID
    ) AS Summe ON Summe.LineID = Leitung.LineID;

    -- --- 2. Netzzustand protokollieren ---
    -- Bilanz = freie Reserve abzueglich der neu benoetigten Zusatzreserve.
    -- Ein negativer Wert bedeutet Unterdeckung.
    INSERT INTO GridBalanceLogs (TransactionID, PostTransactionBalanceMW)
    SELECT  neu.TransactionID,
            CAST(ISNULL(Reserve.AvailableReserveMW - Reserve.RequiredReserveMW, 0)
                 - (neu.TotalMWh * 0.15) AS DECIMAL(10,2))
    FROM inserted AS neu
    LEFT JOIN ReserveSchedules AS Reserve ON neu.DeliveryTimeSlot >= Reserve.StartTime
                                   AND neu.DeliveryTimeSlot <  Reserve.EndTime;

    -- --- 3. Auditing ---
    INSERT INTO SystemLogs (LogLevel, Message)
    SELECT  'INFO',
            CONCAT(N'Export gebucht: Transaktion ', neu.TransactionID,
                   N', Leitung ', neu.LineID,
                   N', Zielland ', Land.CountryName,
                   N', Menge ', neu.TotalMWh, N' MWh',
                   N', Wert ', neu.TotalValueEUR, N' EUR',
                   N', Verlust ', dbo.sfCalculateTransmissionLoss(neu.TotalMWh, neu.LineID), N' MWh')
    FROM inserted AS neu
    INNER JOIN TransmissionLines AS Leitung ON Leitung.LineID   = neu.LineID
    INNER JOIN GridNodes         AS Netzknoten ON Netzknoten.NodeID   = Leitung.ToNodeID
    INNER JOIN Countries         AS Land  ON Land.CountryID = Netzknoten.CountryID;
END
GO

/*------------------------------------------------------------------------------
  2. trReleaseCapacityOnCancel - Transactions, AFTER UPDATE: gibt die Kapazitaet bei Stornierung wieder frei
------------------------------------------------------------------------------*/
CREATE OR ALTER TRIGGER trReleaseCapacityOnCancel
ON Transactions
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- UPDATE(Spalte) ist ein Praedikat und liefert keinen Wert,
    -- darf also nicht mit = 0 verglichen werden.
    IF NOT UPDATE(Status)
        RETURN;

    -- Nur echte Statuswechsel nach 'Storniert' behandeln
    IF NOT EXISTS (
        SELECT 1
        FROM inserted AS neu
        INNER JOIN deleted AS alt ON alt.TransactionID = neu.TransactionID
        WHERE neu.Status = 'Storniert' AND alt.Status <> 'Storniert'
    )
        RETURN;

    -- --- 1. belegte Kapazitaet zurueckbuchen ---
    UPDATE Leitung
    SET Leitung.BookedMWh = CASE WHEN Leitung.BookedMWh - Summe.Menge < 0 THEN 0
                            ELSE Leitung.BookedMWh - Summe.Menge END
    FROM TransmissionLines AS Leitung
    INNER JOIN (
        SELECT neu.LineID, SUM(neu.TotalMWh) AS Menge
        FROM inserted AS neu
        INNER JOIN deleted AS alt ON alt.TransactionID = neu.TransactionID
        WHERE neu.Status = 'Storniert' AND alt.Status <> 'Storniert'
        GROUP BY neu.LineID
    ) AS Summe ON Summe.LineID = Leitung.LineID;

    -- --- 2. Auditing ---
    INSERT INTO SystemLogs (LogLevel, Message)
    SELECT  'WARNING',
            CONCAT(N'Export storniert: Transaktion ', neu.TransactionID,
                   N', Leitung ', neu.LineID,
                   N', Menge ', neu.TotalMWh, N' MWh wieder freigegeben.')
    FROM inserted AS neu
    INNER JOIN deleted AS alt ON alt.TransactionID = neu.TransactionID
    WHERE neu.Status = 'Storniert' AND alt.Status <> 'Storniert';
END
GO

/*------------------------------------------------------------------------------
  3. trLogPlantAllocation - TransactionPlantAllocations, AFTER INSERT/UPDATE: warnt bei abweichender Zuteilungssumme
------------------------------------------------------------------------------*/
CREATE OR ALTER TRIGGER trLogPlantAllocation
ON TransactionPlantAllocations
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM inserted)
        RETURN;

    INSERT INTO SystemLogs (LogLevel, Message)
    SELECT  'WARNING',
            CONCAT(N'Zuteilung weicht ab: Transaktion ', Lieferung.TransactionID,
                   N' hat ', Lieferung.TotalMWh, N' MWh, zugeteilt sind ', Zuteilungssumme.Summe, N' MWh.')
    FROM (SELECT DISTINCT TransactionID FROM inserted) AS Betroffene
    INNER JOIN Transactions AS Lieferung ON Lieferung.TransactionID = Betroffene.TransactionID
    CROSS APPLY (
        SELECT SUM(AllocatedMWh) AS Summe
        FROM TransactionPlantAllocations
        WHERE TransactionID = Betroffene.TransactionID
    ) AS Zuteilungssumme
    WHERE ABS(Lieferung.TotalMWh - Zuteilungssumme.Summe) > 1.00;   -- Rundungstoleranz
END
GO

/*------------------------------------------------------------------------------
  4. trPreventReserveOverlap - ReserveSchedules, AFTER INSERT/UPDATE: verhindert ueberlappende Zeitfenster
------------------------------------------------------------------------------*/
CREATE OR ALTER TRIGGER trPreventReserveOverlap
ON ReserveSchedules
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM inserted)
        RETURN;

    IF EXISTS (
        SELECT 1
        FROM inserted AS neu
        INNER JOIN ReserveSchedules AS Reserve
                ON Reserve.ScheduleID <> neu.ScheduleID          -- nicht mit sich selbst
               AND neu.StartTime   <  Reserve.EndTime
               AND Reserve.StartTime  <  neu.EndTime
    )
    BEGIN
        INSERT INTO SystemLogs (LogLevel, Message)
        VALUES ('ERROR', N'Reservefahrplan abgelehnt: das Zeitfenster ueberlappt einen bestehenden Eintrag.');

        RAISERROR (N'Das Zeitfenster ueberlappt einen bestehenden Reservefahrplan.', 16, 1);
        ROLLBACK TRANSACTION;
        RETURN;
    END
END
GO

/*------------------------------------------------------------------------------
  5. trAuditExportContracts - ExportContracts, AFTER INSERT/UPDATE: protokolliert Anlage und Preisaenderung
------------------------------------------------------------------------------*/
CREATE OR ALTER TRIGGER trAuditExportContracts
ON ExportContracts
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- Neuanlage: in inserted stehen Zeilen, in deleted nicht
    IF EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted)
    BEGIN
        INSERT INTO ContractAuditLogs (ContractID, ActionType, Details)
        SELECT  neu.ContractID,
                'INSERT',
                CONCAT('Neuer Vertrag. Exporteur ', neu.ExporterCountryID,
                       ', Importeur ', neu.ImporterCountryID,
                       ', Preis ', neu.AgreedPricePerMWh, ' EUR/MWh')
        FROM inserted AS neu;
    END

    -- Aenderung: nur protokollieren, wenn sich der Preis wirklich geaendert hat
    IF EXISTS (SELECT 1 FROM inserted) AND EXISTS (SELECT 1 FROM deleted)
    BEGIN
        INSERT INTO ContractAuditLogs (ContractID, ActionType, Details)
        SELECT  neu.ContractID,
                'UPDATE',
                CONCAT('Preis geaendert von ', alt.AgreedPricePerMWh,
                       ' auf ', neu.AgreedPricePerMWh, ' EUR/MWh')
        FROM inserted AS neu
        INNER JOIN deleted AS alt ON alt.ContractID = neu.ContractID
        WHERE neu.AgreedPricePerMWh <> alt.AgreedPricePerMWh;
    END
END;
GO

/*---------------- Kontrolle ----------------*/
SELECT name AS Trigger_Name, is_disabled AS Deaktiviert
FROM sys.triggers
WHERE name = 'trAuditExportContracts';
GO

/*------------------------------------------------------------------------------
  Kontrolle: fuenf Trigger, keiner deaktiviert
------------------------------------------------------------------------------*/
SELECT  Trigger_.name                      AS Trigger_Name,
        OBJECT_NAME(Trigger_.parent_id)    AS Tabelle,
        Trigger_.is_disabled               AS IstDeaktiviert
FROM sys.triggers AS Trigger_
WHERE Trigger_.parent_id > 0
ORDER BY Tabelle, Trigger_Name;
GO
