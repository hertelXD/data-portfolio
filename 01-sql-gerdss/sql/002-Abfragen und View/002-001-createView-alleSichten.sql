/*==============================================================================
  Projekt : GERDSS - German Energy Export Decision Support System
  Author  : Aileen Hertel
  Datei   : 002-001-createView-alleSichten.sql
  Zweck   : Alle sieben Sichten der Datenbank in einem Skript. Die Sichten decken
            die geforderten Verknuepfungsarten ab: INNER JOIN, GROUP BY mit
            HAVING, LEFT OUTER JOIN und SELF JOIN.
  Technik : CREATE OR ALTER VIEW, INNER JOIN, LEFT OUTER JOIN, SELF JOIN,
            GROUP BY mit HAVING, SUM, COUNT, AVG, MIN, MAX, ISNULL, CASE,
            DATEDIFF, eigene Skalarwertfunktionen
==============================================================================*/

USE dbGERDSS;
GO

SET ANSI_NULLS ON;                                           -- ISO-Standard fuer NULL-Vergleiche
GO

SET QUOTED_IDENTIFIER ON;                                    -- Erlaubt doppelt gesetzte Bezeichner
GO

/*------------------------------------------------------------------------------
  1. vwCountryExportSummary - Menge, Erloes und Kreditauslastung je Zielland. GROUP BY mit HAVING
------------------------------------------------------------------------------*/

CREATE OR ALTER VIEW vwCountryExportSummary AS
SELECT
    Land.CountryName                       AS Zielland,         -- Name des Importlandes
    Land.CountryCode,                                           -- ISO-Kuerzel
    COUNT(Lieferung.TransactionID)              AS AnzahlLieferungen,-- Anzahl der Buchungen
    SUM(Lieferung.TotalMWh)                     AS SummeMWh,         -- gelieferte Gesamtmenge
    SUM(Lieferung.TotalValueEUR)                AS ErloesEUR,        -- Umsatz mit diesem Land
    AVG(Lieferung.TotalValueEUR / Lieferung.TotalMWh)   AS DurchschnittspreisEUR,   -- mittlerer Preis je MWh
    SUM(Lieferung.TotalMWh - dbo.sfCalculateNetPower(Lieferung.TotalMWh, Leitung.LossPercentage)) AS VerlustMWh,  -- eigene Funktion
    MIN(Lieferung.DeliveryTimeSlot)             AS ErsteLieferung,   -- aelteste Lieferung
    MAX(Lieferung.DeliveryTimeSlot)             AS LetzteLieferung,  -- juengste Lieferung
    DATEDIFF(DAY, MAX(Lieferung.DeliveryTimeSlot), SYSDATETIME()) AS TageSeitLetzterLieferung,
    Land.CreditLimitEUR,                                        -- vereinbarte Obergrenze
    Land.CreditLimitEUR - SUM(Lieferung.TotalValueEUR) AS FreierKreditEUR    -- noch verfuegbarer Rahmen
FROM Transactions AS Lieferung
INNER JOIN TransmissionLines AS Leitung ON Leitung.LineID   = Lieferung.LineID     -- genutzte Leitung
INNER JOIN GridNodes         AS Netzknoten ON Netzknoten.NodeID   = Leitung.ToNodeID  -- Zielknoten der Leitung
INNER JOIN Countries         AS Land  ON Land.CountryID = Netzknoten.CountryID -- Land des Zielknotens
WHERE Lieferung.Status <> 'Storniert'                                    -- Stornos zaehlen nicht zum Erloes
GROUP BY Land.CountryName, Land.CountryCode, Land.CreditLimitEUR
HAVING SUM(Lieferung.TotalMWh) > 100;                                    -- Filter auf die Gruppe, nicht auf die Zeile
GO

/*------------------------------------------------------------------------------
  2. vwActiveGridCapacity - Auslastung aller aktiven Leitungen. INNER JOIN ueber vier Tabellen

  Achtung, zwei verschiedene Groessen:
  BookedMWh ist ein kumulativer Zaehler ueber alle Zeitfenster, den
  trUpdateGridBalance fortschreibt. Die Kapazitaetspruefung der Prozedur
  (Stufe 1) rechnet dagegen je Zeitfenster ueber sfGetAvailableCapacity.
  Diese Sicht zeigt die Gesamtauslastung, nicht die freie Kapazitaet
  eines einzelnen Zeitfensters.
------------------------------------------------------------------------------*/
CREATE OR ALTER VIEW vwActiveGridCapacity
AS
SELECT  Leitung.LineID,
        StartKnoten.NodeName                 AS VonKnoten,           -- Startknoten der Leitung
        ZielKnoten.NodeName                 AS NachKnoten,          -- Zielknoten der Leitung
        StartLand.CountryName              AS VonLand,             -- Land des Startknotens
        ZielLand.CountryName              AS NachLand,            -- Land des Zielknotens
        Leitung.MaxCapacityMW,                                   -- physische Obergrenze
        Leitung.BookedMWh,                                       -- kumuliert belegt, vom Trigger gepflegt
        Leitung.MaxCapacityMW * 24 - Leitung.BookedMWh AS RestkapazitaetMWh,  -- Tageskapazitaet minus kumulierter Belegung
        Leitung.LossPercentage,                                  -- Verlust bei der Durchleitung
        Leitung.LengthKM,                                        -- Trassenlaenge
        CAST(Leitung.BookedMWh / (Leitung.MaxCapacityMW * 24) * 100 AS DECIMAL(6,2)) AS AuslastungProzent
FROM TransmissionLines AS Leitung
INNER JOIN GridNodes AS StartKnoten ON StartKnoten.NodeID    = Leitung.FromNodeID  -- erster Bezug auf GridNodes: Startknoten
INNER JOIN GridNodes AS ZielKnoten ON ZielKnoten.NodeID    = Leitung.ToNodeID    -- zweiter Bezug auf GridNodes: Zielknoten
INNER JOIN Countries AS StartLand ON StartLand.CountryID = StartKnoten.CountryID   -- Land ueber den Startknoten
INNER JOIN Countries AS ZielLand ON ZielLand.CountryID = ZielKnoten.CountryID   -- Land ueber den Zielknoten
WHERE Leitung.IsActive = 1;                                      -- ausser Betrieb genommene Trassen ausblenden
GO

/*------------------------------------------------------------------------------
  3. vwNodeConnections - Leitungen mit Start- und Zielknoten. SELF JOIN auf GridNodes
------------------------------------------------------------------------------*/
CREATE OR ALTER VIEW vwNodeConnections
AS
SELECT  Leitung.LineID,
        StartKnoten.NodeName         AS VonKnoten,           -- Name des Startknotens
        StartKnoten.VoltageLevelIKV   AS VonSpannungKV,       -- Spannung am Startknoten
        ZielKnoten.NodeName         AS NachKnoten,          -- Name des Zielknotens
        ZielKnoten.VoltageLevelIKV   AS NachSpannungKV,      -- Spannung am Zielknoten
        Leitung.LengthKM,
        Leitung.MaxCapacityMW,
        CASE                                        -- vergleicht beide Spannungsebenen
            WHEN StartKnoten.VoltageLevelIKV = ZielKnoten.VoltageLevelIKV THEN N'gleiche Spannungsebene'
            ELSE N'Umspannung erforderlich'
        END                 AS Kompatibilitaet,
        CASE
            WHEN Leitung.IsActive = 1 THEN N'in Betrieb'
            ELSE N'ausser Betrieb'
        END                 AS Betriebsstatus
FROM TransmissionLines AS Leitung
INNER JOIN GridNodes AS StartKnoten ON StartKnoten.NodeID = Leitung.FromNodeID   -- erster Bezug: Startknoten
INNER JOIN GridNodes AS ZielKnoten ON ZielKnoten.NodeID = Leitung.ToNodeID;    -- zweiter Bezug: Zielknoten
GO

/*------------------------------------------------------------------------------
  4. vwCO2Balance - Emissionen und Einsparung je Zielland und Technologie
------------------------------------------------------------------------------*/
CREATE OR ALTER VIEW vwCO2Balance
AS
SELECT  Land.CountryName                   AS Zielland,
        Technologie.TypeName                     AS Technologie,
        Technologie.IsRenewable,                                     -- 1 = erneuerbare Quelle
        SUM(Zuteilung.AllocatedMWh)           AS GelieferteMWh,   -- Summe der Kraftwerksanteile
        SUM(dbo.sfCalculateCO2Emission(Zuteilung.AllocatedMWh, Zuteilung.PlantID)) AS EmissionTonnen,
        -- Vergleich zum fossilen Referenzmix (Kohle, 0,82 t je MWh)
        SUM(Zuteilung.AllocatedMWh * 0.82)
          - SUM(dbo.sfCalculateCO2Emission(Zuteilung.AllocatedMWh, Zuteilung.PlantID)) AS EinsparungTonnen
FROM TransactionPlantAllocations AS Zuteilung
INNER JOIN Transactions       AS Lieferung  ON Lieferung.TransactionID = Zuteilung.TransactionID  -- zugehoerige Lieferung
INNER JOIN PowerPlants        AS Kraftwerk  ON Kraftwerk.PlantID       = Zuteilung.PlantID        -- einspeisendes Kraftwerk
INNER JOIN PowerPlantTypes    AS Technologie ON Technologie.PlantTypeID  = Kraftwerk.PlantTypeID      -- Technologie mit CO2-Faktor
INNER JOIN TransmissionLines  AS Leitung ON Leitung.LineID       = Lieferung.LineID           -- genutzte Leitung
INNER JOIN GridNodes          AS Netzknoten ON Netzknoten.NodeID       = Leitung.ToNodeID        -- Zielknoten
INNER JOIN Countries          AS Land  ON Land.CountryID     = Netzknoten.CountryID       -- Zielland
GROUP BY Land.CountryName, Technologie.TypeName, Technologie.IsRenewable;
GO

/*------------------------------------------------------------------------------
  5. vwReserveSituation - Reservelage je Stundenfenster mit dem exportierten Volumen
------------------------------------------------------------------------------*/
CREATE OR ALTER VIEW vwReserveSituation
AS
SELECT  Reserve.StartTime,                                       -- Beginn des Zeitfensters
        Reserve.EndTime,                                         -- Ende des Zeitfensters
        DATEPART(HOUR, Reserve.StartTime)    AS Stunde,          -- Stunde als Zahl fuer die Einordnung
        Reserve.AvailableReserveMW,                              -- vorgehaltene Reserve
        Reserve.RequiredReserveMW,                               -- gesetzliches Minimum
        Reserve.AvailableReserveMW - Reserve.RequiredReserveMW AS FreieReserveMW,  -- Puffer
        ISNULL(SUM(Lieferung.TotalMWh), 0)      AS ExportiertMWh,   -- ISNULL, weil Stunden ohne Lieferung NULL liefern
        CASE                                                -- Hochlastzeit oder Schwachlastzeit
            WHEN DATEPART(HOUR, Reserve.StartTime) BETWEEN 8 AND 19 THEN N'Peak'
            ELSE N'Offpeak'
        END                             AS Lastzeitfenster
FROM ReserveSchedules AS Reserve
LEFT OUTER JOIN Transactions AS Lieferung ON Lieferung.DeliveryTimeSlot >= Reserve.StartTime   -- Bereichsvergleich statt Gleichheit,
                                 AND Lieferung.DeliveryTimeSlot <  Reserve.EndTime     -- weil das Fenster Start und Ende hat
                                 AND Lieferung.Status <> 'Storniert'              -- Stornos zaehlen nicht
GROUP BY Reserve.StartTime, Reserve.EndTime, Reserve.AvailableReserveMW, Reserve.RequiredReserveMW;
GO

/*------------------------------------------------------------------------------
  6. vwInactiveTradeRoutes - Potenzialmaerkte: Laender ohne Netzanbindung. LEFT OUTER JOIN
------------------------------------------------------------------------------*/
CREATE OR ALTER VIEW vwInactiveTradeRoutes
AS
SELECT  Land.CountryID,
        Land.CountryName,
        Land.CountryCode,
        Land.GridOperator,
        Land.CreditLimitEUR,
        Netzknoten.NodeName             AS Grenzknoten,         -- NULL = kein Knoten vorhanden
        Leitung.LineID,                                      -- NULL = keine Leitung vorhanden
        Leitung.IsActive,                                    -- 0 = Leitung ausser Betrieb
        MAX(Lieferung.DeliveryTimeSlot) AS LetzteLieferung,     -- NULL = nie geliefert
        COUNT(Lieferung.TransactionID)  AS AnzahlLieferungen,
        CASE                                            -- wertet die NULL-Werte fachlich aus
            WHEN Netzknoten.NodeID IS NULL          THEN N'Kein Netzknoten vorhanden'
            WHEN Leitung.LineID IS NULL          THEN N'Knoten ohne Leitungsanbindung'
            WHEN Leitung.IsActive = 0            THEN N'Leitung ausser Betrieb'
            WHEN COUNT(Lieferung.TransactionID) = 0 THEN N'Leitung vorhanden, nie genutzt'
            ELSE N'Aktiver Markt'
        END                     AS Marktstatus
FROM Countries AS Land
LEFT OUTER JOIN GridNodes         AS Netzknoten ON Netzknoten.CountryID = Land.CountryID   -- Laender ohne Knoten bleiben erhalten
LEFT OUTER JOIN TransmissionLines AS Leitung ON Leitung.ToNodeID  = Netzknoten.NodeID     -- Knoten ohne Leitung bleiben erhalten
LEFT OUTER JOIN Transactions      AS Lieferung  ON Lieferung.LineID     = Leitung.LineID     -- Leitungen ohne Lieferung bleiben erhalten
WHERE Land.CountryCode <> 'DE'                                             -- alle ausser dem Exportland
GROUP BY Land.CountryID, Land.CountryName, Land.CountryCode, Land.GridOperator,
         Land.CreditLimitEUR, Netzknoten.NodeID, Netzknoten.NodeName, Leitung.LineID, Leitung.IsActive;
GO

/*------------------------------------------------------------------------------
  7. vwCO2EinsparungZielland - Einsparung je Zielland gegen den Emissionsfaktor des Zielnetzes
------------------------------------------------------------------------------*/
CREATE OR ALTER VIEW vwCO2EinsparungZielland AS
SELECT  Land.CountryName                       AS Zielland,
        Land.GridEmissionFactor                AS FaktorZielnetz,
        SUM(Zuteilung.AllocatedMWh)               AS GelieferteMWh,
        SUM(dbo.sfCalculateCO2Emission(Zuteilung.AllocatedMWh, Zuteilung.PlantID)) AS EigeneEmissionTonnen,
        SUM(Zuteilung.AllocatedMWh * Land.GridEmissionFactor)                   AS VermiedeneEmissionTonnen,
        SUM(Zuteilung.AllocatedMWh * Land.GridEmissionFactor)
          - SUM(dbo.sfCalculateCO2Emission(Zuteilung.AllocatedMWh, Zuteilung.PlantID)) AS EinsparungTonnen
FROM TransactionPlantAllocations AS Zuteilung
INNER JOIN Transactions      AS Lieferung  ON Lieferung.TransactionID = Zuteilung.TransactionID
INNER JOIN TransmissionLines AS Leitung ON Leitung.LineID       = Lieferung.LineID
INNER JOIN GridNodes         AS Netzknoten ON Netzknoten.NodeID       = Leitung.ToNodeID     -- Zielknoten
INNER JOIN Countries         AS Land  ON Land.CountryID     = Netzknoten.CountryID    -- Zielland
GROUP BY Land.CountryName, Land.GridEmissionFactor;
GO

/*------------------------------------------------------------------------------
  Kontrolle: alle sieben Sichten liefern Zeilen
------------------------------------------------------------------------------*/
SELECT * FROM vwCountryExportSummary;
SELECT * FROM vwActiveGridCapacity      ORDER BY AuslastungProzent DESC;
SELECT * FROM vwNodeConnections         ORDER BY LineID;
SELECT * FROM vwCO2Balance              ORDER BY Zielland, Technologie;
SELECT * FROM vwReserveSituation        ORDER BY StartTime;
SELECT * FROM vwInactiveTradeRoutes;
SELECT * FROM vwCO2EinsparungZielland   ORDER BY EinsparungTonnen DESC;
GO
