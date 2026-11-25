/*==============================================================================
  Projekt : GERDSS - German Energy Export Decision Support System
  Author  : Aileen Hertel
  Datei   : 004-002-spExecuteEnergyExport.sql
  Zweck   : Zentrale Prozedur der Businesslogik. Prueft vor jeder Buchung drei
            Bedingungen nacheinander und bricht bei der ersten Verletzung ab:
              Stufe 1  Netzkapazitaet der Leitung im Zeitfenster
              Stufe 2  Kreditrahmen des Importlandes
              Stufe 3  verbleibende Regelreserve im Netz
            Erst danach wird gebucht und die Menge auf die Kraftwerke verteilt.
  Technik : CREATE PROCEDURE mit Eingangs- und OUTPUT-Parametern, Pruefung der
            Eingangsparameter, eigene Skalarwertfunktion sfGetAvailableCapacity,
            RAISERROR mit Formatplatzhaltern, TRY...CATCH, TRANSACTION mit
            COMMIT und ROLLBACK, SCOPE_IDENTITY, CTE mit TOP und ORDER BY,
            INSERT ... SELECT

  Reihenfolge der Pruefungen: von der guenstigsten zur aufwendigsten. Stufe 1
  liest eine Tabelle, Stufe 2 braucht zusaetzlich die Preisermittlung, Stufe 3
  setzt auf der bereits ermittelten Menge auf.

  Zum Kreditrahmen: CreditLimitEUR bleibt unveraendert. Der ausgeschoepfte
  Betrag wird zur Laufzeit aus den Transaktionen summiert. Damit bleibt der
  urspruengliche Rahmen erhalten und auswertbar.

  Fassung 5 (26.08.2026): Die Verteilung laeuft nur noch ueber die 30
  Hauptkraftwerke statt ueber alle 124 erneuerbaren Anlagen. Ausgewaehlt wird
  nach Merit Order - niedrigster CO2-Faktor zuerst, bei gleichem Faktor die
  groessere Anlage. Das ist dieselbe Reihenfolge, nach der die externe
  Optimierung auswaehlt, und es entspricht der Praxis: eine Lieferung wird
  nicht auf jede Kleinanlage im Netz aufgeteilt.

  Fassung 4: Die Fehlertexte stehen direkt im RAISERROR statt als registrierte
  Nummern. Grund: sp_addmessage wandelt die Platzhalter beim Speichern um, und
  in einer deutschsprachigen Sitzung liess sich die Meldung danach nicht mehr
  aufloesen - ERROR_MESSAGE() kam leer im CATCH an.

  Fassung 3: Parameter @VerteilungExtern. Steht er auf 1, verteilt die Prozedur
  die Menge nicht selbst - dann liefert die externe Optimierung die Zuteilung.

  Fassung 2: Die Transaktion wird VOR Pruefstufe 1 geoeffnet und die Leitung mit
  WITH (UPDLOCK, HOLDLOCK) gelesen. Ohne diese Sperre koennen zwei gleichzeitige
  Buchungen dieselbe freie Kapazitaet sehen und die Leitung ueberbuchen.
==============================================================================*/

USE dbGERDSS;
GO

CREATE OR ALTER PROCEDURE dbo.spExecuteEnergyExport
(
    @LineID             INT,                        -- Eingang: Leitung
    @DeliveryTimeSlot   DATETIME2(0),               -- Eingang: Lieferzeitraum
    @TotalMWh           DECIMAL(12,2),              -- Eingang: Menge
    @PricePerMWh        DECIMAL(10,2)   = NULL,     -- optional, sonst Vertrags- oder Marktpreis
    @VerteilungExtern   BIT             = 0,        -- 1 = Kraftwerksverteilung kommt von aussen
    @TransactionID      INT             OUTPUT,     -- Ausgang: neue Buchung oder NULL
    @Fehlermeldung      NVARCHAR(400)   OUTPUT      -- Ausgang: Grund der Ablehnung
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;

    SET @TransactionID = NULL;
    SET @Fehlermeldung = NULL;

    DECLARE @ToNodeID           INT;
    DECLARE @ImporterCountryID  INT;
    DECLARE @IsActive           BIT;
    DECLARE @ContractID         INT;

    DECLARE @FreieKapazitaet    DECIMAL(12,2);
    DECLARE @CreditLimit        DECIMAL(15,2);
    DECLARE @Verbraucht         DECIMAL(15,2);
    DECLARE @FreierKredit       DECIMAL(15,2);
    DECLARE @Auftragswert       DECIMAL(15,2);

    DECLARE @ExportMW           DECIMAL(12,2);
    DECLARE @Zusatzreserve      DECIMAL(12,2);
    DECLARE @Available          DECIMAL(10,2);
    DECLARE @Required           DECIMAL(10,2);
    DECLARE @FreieReserve       DECIMAL(12,2);

    -- Zahl der Hauptkraftwerke, auf die verteilt wird. Dieselbe Groesse, mit
    -- der die externe Optimierung arbeitet.
    DECLARE @AnzahlHauptkraftwerke INT = 30;

    -- Texthilfsvariablen: RAISERROR kann keine DECIMAL-Werte einsetzen,
    -- deshalb werden Betraege vorher in Zeichenketten umgewandelt.
    DECLARE @t1 NVARCHAR(30), @t2 NVARCHAR(30), @t3 NVARCHAR(30);

    BEGIN TRY

/*----------------------------------------------------------------------------
  VORPRUEFUNG der Eingangsparameter
----------------------------------------------------------------------------*/
        SELECT  @ToNodeID          = Leitung.ToNodeID,
                @IsActive          = Leitung.IsActive,
                @ImporterCountryID = Netzknoten.CountryID
        FROM TransmissionLines AS Leitung
        INNER JOIN GridNodes AS Netzknoten ON Netzknoten.NodeID = Leitung.ToNodeID
        WHERE Leitung.LineID = @LineID;

        IF @ToNodeID IS NULL
            RAISERROR (N'Vorpruefung fehlgeschlagen: Die angegebene Leitung existiert nicht.', 16, 1);

        IF @IsActive = 0
            RAISERROR (N'Vorpruefung fehlgeschlagen: Die Leitung ist ausser Betrieb.', 16, 1);

        IF @TotalMWh IS NULL OR @TotalMWh <= 0
            RAISERROR (N'Vorpruefung fehlgeschlagen: Die Liefermenge muss groesser als null sein.', 16, 1);

        IF @DeliveryTimeSlot IS NULL
            RAISERROR (N'Vorpruefung fehlgeschlagen: Es wurde kein Lieferzeitraum angegeben.', 16, 1);

/*----------------------------------------------------------------------------
  SPERRE - ab hier laeuft die Buchung in einer Transaktion
  Die Leitung wird gesperrt, damit keine zweite Buchung dieselbe freie
  Kapazitaet sieht. Die Sperre endet mit COMMIT oder ROLLBACK.
----------------------------------------------------------------------------*/
        BEGIN TRANSACTION;

        DECLARE @GesperrteLeitung INT;

        SELECT @GesperrteLeitung = Leitung.LineID
        FROM TransmissionLines AS Leitung WITH (UPDLOCK, HOLDLOCK)
        WHERE Leitung.LineID = @LineID;

/*----------------------------------------------------------------------------
  STUFE 1 - Netzkapazitaet der Leitung im Zeitfenster
----------------------------------------------------------------------------*/
        SET @FreieKapazitaet = dbo.sfGetAvailableCapacity(@LineID, @DeliveryTimeSlot);

        IF @FreieKapazitaet < @TotalMWh
        BEGIN
            SET @t1 = CAST(@TotalMWh        AS NVARCHAR(30));
            SET @t2 = CAST(@FreieKapazitaet AS NVARCHAR(30));
            RAISERROR (N'Stufe 1 - Kapazitaetspruefung fehlgeschlagen: benoetigt %s MWh, frei sind nur %s MWh.',
                       16, 1, @t1, @t2);
        END

/*----------------------------------------------------------------------------
  PREISFINDUNG - Vertragspreis vor Marktpreis
----------------------------------------------------------------------------*/
        SELECT TOP (1)
               @ContractID  = Vertrag.ContractID,
               @PricePerMWh = ISNULL(@PricePerMWh, Vertrag.AgreedPricePerMWh)
        FROM ExportContracts AS Vertrag
        WHERE Vertrag.ImporterCountryID = @ImporterCountryID
          AND Vertrag.ContractStartDate <= @DeliveryTimeSlot
          AND (Vertrag.ContractEndDate IS NULL OR Vertrag.ContractEndDate >= @DeliveryTimeSlot)
        ORDER BY Vertrag.ContractStartDate DESC;

        IF @PricePerMWh IS NULL
            SELECT TOP (1) @PricePerMWh = Marktpreis.PricePerMWh
            FROM MarketPrices AS Marktpreis
            WHERE Marktpreis.CountryID = @ImporterCountryID
            ORDER BY ABS(DATEDIFF(MINUTE, Marktpreis.TimeSlot, @DeliveryTimeSlot));

        IF @PricePerMWh IS NULL
            RAISERROR (N'Vorpruefung fehlgeschlagen: Es konnte kein Preis ermittelt werden (kein Vertrag, keine Marktpreise).',
                       16, 1);

/*----------------------------------------------------------------------------
  STUFE 2 - Kreditrahmen des Importlandes
----------------------------------------------------------------------------*/
        SELECT @CreditLimit = CreditLimitEUR
        FROM Countries
        WHERE CountryID = @ImporterCountryID;

        SET @Auftragswert = @TotalMWh * @PricePerMWh;
        SET @t2 = CAST(@Auftragswert AS NVARCHAR(30));

        IF @CreditLimit IS NULL OR @CreditLimit = 0
            RAISERROR (N'Stufe 2 - Finanzpruefung fehlgeschlagen: Zielland hat keinen Kreditrahmen. Auftragswert %s EUR, freier Kreditrahmen 0.00 EUR.',
                       16, 1, @t2);

        -- bereits ausgeschoepfter Betrag, zur Laufzeit summiert
        SELECT @Verbraucht = ISNULL(SUM(Lieferung.TotalValueEUR), 0)
        FROM Transactions AS Lieferung
        INNER JOIN TransmissionLines AS Leitung ON Leitung.LineID = Lieferung.LineID
        INNER JOIN GridNodes         AS Netzknoten ON Netzknoten.NodeID = Leitung.ToNodeID
        WHERE Netzknoten.CountryID = @ImporterCountryID;

        SET @FreierKredit = @CreditLimit - @Verbraucht;

        IF @FreierKredit < @Auftragswert
        BEGIN
            SET @t3 = CAST(@FreierKredit AS NVARCHAR(30));
            RAISERROR (N'Stufe 2 - Finanzpruefung fehlgeschlagen: Kreditrahmen ausgeschoepft. Auftragswert %s EUR, freier Kreditrahmen %s EUR.',
                       16, 1, @t2, @t3);
        END

/*----------------------------------------------------------------------------
  STUFE 3 - Stabilitaetsreserve
  Fuer jede exportierte Leistung sind 15 Prozent Regelreserve vorzuhalten.
----------------------------------------------------------------------------*/
        SET @ExportMW      = @TotalMWh;          -- Zeitfenster = eine Stunde
        SET @Zusatzreserve = @ExportMW * 0.15;

        SELECT  @Available = AvailableReserveMW,
                @Required  = RequiredReserveMW
        FROM ReserveSchedules
        WHERE @DeliveryTimeSlot >= StartTime
          AND @DeliveryTimeSlot <  EndTime;

        IF @Available IS NULL
            RAISERROR (N'Vorpruefung fehlgeschlagen: Fuer diesen Zeitraum ist kein Reservefahrplan hinterlegt.', 16, 1);

        SET @FreieReserve = @Available - @Required;

        IF @Zusatzreserve > @FreieReserve
        BEGIN
            SET @t1 = CAST(@ExportMW      AS NVARCHAR(30));
            SET @t2 = CAST(@Zusatzreserve AS NVARCHAR(30));
            SET @t3 = CAST(@FreieReserve  AS NVARCHAR(30));
            RAISERROR (N'Stufe 3 - Netzstabilitaet verletzt: Export %s MW erfordert %s MW Zusatzreserve, frei sind %s MW.',
                       16, 1, @t1, @t2, @t3);
        END

/*----------------------------------------------------------------------------
  BUCHUNG - alle drei Stufen bestanden
  Die Transaktion laeuft bereits seit der Sperre oben.
----------------------------------------------------------------------------*/
        INSERT INTO Transactions (ContractID, LineID, DeliveryTimeSlot, TotalMWh, TotalValueEUR)
        VALUES (@ContractID, @LineID, @DeliveryTimeSlot, @TotalMWh, @Auftragswert);

        SET @TransactionID = SCOPE_IDENTITY();

/*----------------------------------------------------------------------------
  VERTEILUNG auf die Hauptkraftwerke

  Ausgewaehlt werden die 30 erneuerbaren Anlagen mit dem niedrigsten
  CO2-Faktor; bei gleichem Faktor zaehlt die groessere Nennleistung. Innerhalb
  dieser Auswahl wird die Menge im Verhaeltnis der Nennleistung verteilt.

  Dieselbe Reihenfolge verwendet die externe Optimierung. Auf alle 124
  erneuerbaren Anlagen zu verteilen waere rechnerisch moeglich, aber fachlich
  unsinnig - eine einzelne Lieferung wird nicht auf jede Kleinanlage im Netz
  aufgeteilt.

  Steht @VerteilungExtern auf 1, entfaellt dieser Teil: dann traegt
  spImportOptimizedResults die Zuteilung ein, die von aussen berechnet wurde.
----------------------------------------------------------------------------*/
        IF @VerteilungExtern = 0
        BEGIN
            ;WITH Hauptkraftwerke AS
            (
                SELECT TOP (@AnzahlHauptkraftwerke)
                       Kraftwerk.PlantID,
                       Kraftwerk.MaxCapacityMW
                FROM PowerPlants AS Kraftwerk
                INNER JOIN PowerPlantTypes AS Technologie ON Technologie.PlantTypeID = Kraftwerk.PlantTypeID
                WHERE Technologie.IsRenewable = 1
                ORDER BY Technologie.CO2EmissionFactor ASC,     -- sauberste zuerst
                         Kraftwerk.MaxCapacityMW      DESC,     -- dann die groesste
                         Kraftwerk.PlantID            ASC       -- eindeutige Reihenfolge
            )
            INSERT INTO TransactionPlantAllocations (TransactionID, PlantID, AllocatedMWh)
            SELECT  @TransactionID,
                    Auswahl.PlantID,
                    CAST(@TotalMWh * Auswahl.MaxCapacityMW / Gesamtleistung.Gesamt AS DECIMAL(10,2))
            FROM Hauptkraftwerke AS Auswahl
            CROSS JOIN (SELECT SUM(MaxCapacityMW) AS Gesamt FROM Hauptkraftwerke) AS Gesamtleistung
            WHERE CAST(@TotalMWh * Auswahl.MaxCapacityMW / Gesamtleistung.Gesamt AS DECIMAL(10,2)) > 0;
        END

        COMMIT TRANSACTION;

    END TRY
    BEGIN CATCH

        -- Halbfertige Buchungen darf es nicht geben
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        SET @TransactionID = NULL;
        SET @Fehlermeldung = ERROR_MESSAGE();

        INSERT INTO SystemLogs (LogLevel, Message)
        VALUES ('ERROR', @Fehlermeldung);

    END CATCH
END
GO

/*---------------- Kontrolle: Prozedur angelegt, sieben Parameter ----------------*/
SELECT  Parameter.name          AS Parameter,
        Datentyp.name           AS Datentyp,
        Parameter.is_output     AS IstAusgang
FROM sys.procedures AS Prozedur
INNER JOIN sys.parameters AS Parameter ON Parameter.object_id   = Prozedur.object_id
INNER JOIN sys.types      AS Datentyp  ON Datentyp.user_type_id = Parameter.user_type_id
WHERE Prozedur.name = 'spExecuteEnergyExport'
ORDER BY Parameter.parameter_id;
GO

/*---------------- Kontrolle: welche 30 Anlagen ausgewaehlt werden ----------------*/
SELECT TOP (30)
        Kraftwerk.PlantID,
        Kraftwerk.PlantName,
        Technologie.TypeName,
        Technologie.CO2EmissionFactor,
        Kraftwerk.MaxCapacityMW
FROM PowerPlants AS Kraftwerk
INNER JOIN PowerPlantTypes AS Technologie ON Technologie.PlantTypeID = Kraftwerk.PlantTypeID
WHERE Technologie.IsRenewable = 1
ORDER BY Technologie.CO2EmissionFactor ASC, Kraftwerk.MaxCapacityMW DESC, Kraftwerk.PlantID ASC;
-- Erwartet: 26 WindOnshore und 4 WindOffshore, zusammen 9.369,97 MW
GO