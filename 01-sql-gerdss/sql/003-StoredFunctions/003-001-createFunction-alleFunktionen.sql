/*==============================================================================
  Projekt : GERDSS - German Energy Export Decision Support System
  Author  : Aileen Hertel
  Datei   : 003-001-createFunction-alleFunktionen.sql
  Zweck   : Alle fuenf gespeicherten Funktionen in einem Skript: vier
            Skalarwertfunktionen und eine Tabellenwertfunktion.
  Technik : CREATE OR ALTER FUNCTION, RETURNS DECIMAL (Skalarwert),
            RETURNS TABLE (Tabellenwert), IF...ELSE, Unterabfrage mit SUM,
            INNER JOIN in der Funktion, Aufruf einer eigenen Funktion
==============================================================================*/

USE dbGERDSS;
GO

SET ANSI_NULLS ON;                                           -- ISO-Standard fuer NULL-Vergleiche
GO

SET QUOTED_IDENTIFIER ON;                                    -- Erlaubt doppelt gesetzte Bezeichner
GO

/*------------------------------------------------------------------------------
  1. sfCalculateNetPower - Skalarwertfunktion: Nettoleistung nach Abzug der Uebertragungsverluste
------------------------------------------------------------------------------*/
-- Berechnet die Nettoleistung nach Abzug der Uebertragungsverluste
CREATE OR ALTER FUNCTION dbo.sfCalculateNetPower
(
    @GrossPowerMW DECIMAL(10,2),                             -- Uebergabeparameter: Bruttoleistung in MW
    @LossPercentage DECIMAL(5,2)                             -- Uebergabeparameter: Verlust in Prozent
)
RETURNS DECIMAL(10,2)                                        -- Rueckgabetyp: Nettoleistung als Dezimalzahl
AS
BEGIN
    DECLARE @NetPowerMW DECIMAL(10,2);                       -- Lokale Variable fuer das Berechnungsergebnis
    
    -- Pruefung auf ungueltige oder fehlende Werte
    IF @GrossPowerMW IS NULL OR @LossPercentage IS NULL OR @GrossPowerMW <= 0
        SET @NetPowerMW = 0.00;                              -- Setzt Nettoleistung auf 0, falls Werte ungueltig sind
    ELSE
        -- Formel: Netto = Brutto * (1 - (Verlustprozent / 100))
        SET @NetPowerMW = @GrossPowerMW * (1.00 - (@LossPercentage / 100.00));
        
    RETURN @NetPowerMW;                                      -- Gibt das finale Netto-Ergebnis zurueck
END;
GO

/*------------------------------------------------------------------------------
  2. sfCalculateTransmissionLoss - Skalarwertfunktion: Verlustmenge einer Lieferung auf einer Leitung
------------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION dbo.sfCalculateTransmissionLoss
(
    @TotalMWh   DECIMAL(12,2),   -- gelieferte Menge
    @LineID     INT              -- genutzte Leitung
)
RETURNS DECIMAL(12,3)            -- Verlust in MWh
AS
BEGIN
    DECLARE @Loss DECIMAL(5,2);

    SELECT @Loss = LossPercentage
    FROM TransmissionLines
    WHERE LineID = @LineID;

    -- Unbekannte Leitung oder fehlende Menge: kein Ergebnis moeglich
    IF @Loss IS NULL OR @TotalMWh IS NULL
        RETURN NULL;

    RETURN CAST(@TotalMWh * @Loss / 100.0 AS DECIMAL(12,3));
END
GO

/*------------------------------------------------------------------------------
  3. sfGetAvailableCapacity - Skalarwertfunktion: freie Kapazitaet einer Leitung im Zeitfenster
------------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION dbo.sfGetAvailableCapacity
(
    @LineID     INT,
    @TimeSlot   DATETIME2(0)
)
RETURNS DECIMAL(12,2)            -- freie Kapazitaet in MWh
AS
BEGIN
    DECLARE @Max        DECIMAL(10,2);
    DECLARE @IsActive   BIT;
    DECLARE @Gebucht    DECIMAL(12,2);

    SELECT @Max = MaxCapacityMW, @IsActive = IsActive
    FROM TransmissionLines
    WHERE LineID = @LineID;

    -- Leitung existiert nicht oder ist ausser Betrieb: keine Kapazitaet
    IF @Max IS NULL OR @IsActive = 0
        RETURN 0;

    SELECT @Gebucht = ISNULL(SUM(TotalMWh), 0)
    FROM Transactions
    WHERE LineID = @LineID
      AND DeliveryTimeSlot = @TimeSlot
      AND Status <> 'Storniert';

    RETURN CAST(@Max - @Gebucht AS DECIMAL(12,2));
END
GO

/*------------------------------------------------------------------------------
  4. sfCalculateCO2Emission - Skalarwertfunktion: CO2-Ausstoss einer Kraftwerkszuteilung
------------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION dbo.sfCalculateCO2Emission
(
    @AllocatedMWh   DECIMAL(10,2),
    @PlantID        INT
)
RETURNS DECIMAL(12,3)            -- Emission in Tonnen
AS
BEGIN
    DECLARE @Faktor DECIMAL(6,4);

    SELECT @Faktor = Technologie.CO2EmissionFactor
    FROM PowerPlants AS Kraftwerk
    INNER JOIN PowerPlantTypes AS Technologie ON Technologie.PlantTypeID = Kraftwerk.PlantTypeID
    WHERE Kraftwerk.PlantID = @PlantID;

    IF @Faktor IS NULL OR @AllocatedMWh IS NULL
        RETURN NULL;

    RETURN CAST(@AllocatedMWh * @Faktor AS DECIMAL(12,3));
END
GO

/*------------------------------------------------------------------------------
  5. tfGetRoutesInRadius - Tabellenwertfunktion: aktive Leitungen innerhalb eines Handelsradius
------------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION dbo.tfGetRoutesInRadius
(
    @RadiusKM DECIMAL(8,2)                                   -- Uebergabeparameter: Handelsradius in Kilometern
)
RETURNS TABLE                                                -- Rueckgabetyp: Tabelle statt Einzelwert
AS
RETURN
    SELECT  Leitung.LineID,                                       -- ID der Uebertragungsleitung
            StartKnoten.NodeName             AS VonKnoten,            -- Startknoten
            ZielKnoten.NodeName             AS NachKnoten,           -- Zielknoten
            Land.CountryName           AS Zielland,             -- Land des Zielknotens
            Leitung.LengthKM,                                     -- Trassenlaenge in Kilometern
            Leitung.MaxCapacityMW,                                -- physische Obergrenze
            Leitung.LossPercentage,                               -- Verlust bei der Durchleitung
            dbo.sfCalculateNetPower(Leitung.MaxCapacityMW, Leitung.LossPercentage) AS NettoLeistungMW  -- eigene Skalarfunktion
    FROM TransmissionLines AS Leitung
    INNER JOIN GridNodes AS StartKnoten ON StartKnoten.NodeID    = Leitung.FromNodeID   -- erster Bezug: Startknoten
    INNER JOIN GridNodes AS ZielKnoten ON ZielKnoten.NodeID    = Leitung.ToNodeID     -- zweiter Bezug: Zielknoten
    INNER JOIN Countries AS Land  ON Land.CountryID  = ZielKnoten.CountryID    -- Land ueber den Zielknoten
    WHERE Leitung.IsActive = 1                                        -- nur buchbare Leitungen
      AND Leitung.LengthKM <= @RadiusKM;                              -- innerhalb des Radius
GO

/*------------------------------------------------------------------------------
  Kontrolle: fuenf Funktionen, vier davon skalar
------------------------------------------------------------------------------*/
SELECT  Objekt.name AS Funktion,
        Objekt.type_desc AS Art
FROM sys.objects AS Objekt
WHERE Objekt.type IN ('FN', 'IF', 'TF') AND Objekt.is_ms_shipped = 0
ORDER BY Objekt.name;
GO
