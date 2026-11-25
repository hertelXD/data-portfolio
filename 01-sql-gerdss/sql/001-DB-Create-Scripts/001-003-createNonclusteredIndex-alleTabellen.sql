/*==============================================================================
  Projekt : GERDSS - German Energy Export Decision Support System
  Author  : Aileen Hertel
  Datei   : 001-003-createNonclusteredIndex-alleTabellen.sql
  Zweck   : Sekundaerindizes fuer die haeufigsten Zugriffsmuster.
            Die Primaerschluessel erzeugen bereits je einen gruppierten Index.
  Technik : CREATE NONCLUSTERED INDEX, INCLUDE (Deckspalten),
            gefilterter Index (WHERE), absteigende Sortierung (DESC)

  Hinweis : Vor und nach dem Anlegen dieselbe Abfrage mit eingeschaltetem
            Ausfuehrungsplan laufen lassen (Strg+M). Aus Scans werden Suchen.
==============================================================================*/

USE dbGERDSS;                                                -- Wechsel in die GERDSS-Datenbank
GO

SET ANSI_NULLS ON;                                           -- ISO-Standard fuer NULL-Vergleiche aktivieren
GO

SET QUOTED_IDENTIFIER ON;                                    -- Erlaubt doppelt gesetzte Bezeichner
GO

/*------------------------------------------------------------------------------
  VERGLEICHSMESSUNG

  Diese Abfrage einmal VOR und einmal NACH dem Anlegen der Indizes ausfuehren,
  jeweils mit eingeschaltetem Ausfuehrungsplan (Strg+M).
  Vorher stehen im Plan Index Scans, nachher Indexsuchen.
------------------------------------------------------------------------------*/
SET STATISTICS IO ON;                                        -- zeigt die Lesevorgaenge im Meldungsbereich
SET STATISTICS TIME ON;                                      -- zeigt die Laufzeit im Meldungsbereich
GO

SELECT  Land.CountryName,                                       -- Zielland
        COUNT(*)        AS Lieferungen,                      -- Anzahl der Buchungen
        SUM(Lieferung.TotalMWh) AS SummeMWh                          -- gelieferte Gesamtmenge
FROM Transactions AS Lieferung
INNER JOIN TransmissionLines AS Leitung ON Leitung.LineID   = Lieferung.LineID     -- genutzte Leitung
INNER JOIN GridNodes         AS Netzknoten ON Netzknoten.NodeID   = Leitung.ToNodeID  -- Zielknoten der Leitung
INNER JOIN Countries         AS Land  ON Land.CountryID = Netzknoten.CountryID -- Land des Zielknotens
GROUP BY Land.CountryName;
GO

/*------------------------------------------------------------------------------
  1. IX_Transactions_LineSlot
  Haeufigster Zugriff ueberhaupt: die Kapazitaetspruefung sucht nach Leitung
  und Zeitfenster. Menge und Wert liegen als Deckspalten mit im Index, damit
  die Datenbank die Tabelle gar nicht mehr anfassen muss.
------------------------------------------------------------------------------*/
DROP INDEX IF EXISTS IX_Transactions_LineSlot ON Transactions;   -- loescht den Index, falls vorhanden
CREATE NONCLUSTERED INDEX IX_Transactions_LineSlot
    ON Transactions (LineID, DeliveryTimeSlot)               -- Suchspalten
    INCLUDE (TotalMWh, TotalValueEUR);                       -- Deckspalten
GO

/*------------------------------------------------------------------------------
  2. IX_Transactions_DeliveryTimeSlot
  Unterstuetzt Auswertungen nach Zeitraum, etwa Tages- oder Monatsberichte.
------------------------------------------------------------------------------*/
DROP INDEX IF EXISTS IX_Transactions_DeliveryTimeSlot ON Transactions;
CREATE NONCLUSTERED INDEX IX_Transactions_DeliveryTimeSlot
    ON Transactions (DeliveryTimeSlot);                      -- Suchspalte: Lieferzeitpunkt
GO

/*------------------------------------------------------------------------------
  3. IX_MarketPrices_CountrySlot
  Beschleunigt die Preisermittlung je Land. Absteigend sortiert, weil immer
  der zeitnaechste Preis gesucht wird.
------------------------------------------------------------------------------*/
DROP INDEX IF EXISTS IX_MarketPrices_CountrySlot ON MarketPrices;
CREATE NONCLUSTERED INDEX IX_MarketPrices_CountrySlot
    ON MarketPrices (CountryID, TimeSlot DESC);              -- absteigende Sortierung
GO

/*------------------------------------------------------------------------------
  4. IX_TransmissionLines_ToNode
  Der Zielknoten wird in nahezu jeder Sicht verknuepft.
------------------------------------------------------------------------------*/
DROP INDEX IF EXISTS IX_TransmissionLines_ToNode ON TransmissionLines;
CREATE NONCLUSTERED INDEX IX_TransmissionLines_ToNode
    ON TransmissionLines (ToNodeID);                         -- Suchspalte: Zielknoten
GO

/*------------------------------------------------------------------------------
  5. IX_TransmissionLines_Aktiv
  Gefilterter Index: nur aktive Leitungen sind ueberhaupt buchbar. Der Index
  bleibt dadurch klein und die Suche schnell.
------------------------------------------------------------------------------*/
DROP INDEX IF EXISTS IX_TransmissionLines_Aktiv ON TransmissionLines;
CREATE NONCLUSTERED INDEX IX_TransmissionLines_Aktiv
    ON TransmissionLines (FromNodeID, ToNodeID)              -- Suchspalten
    WHERE IsActive = 1;                                      -- Filterbedingung
GO

/*------------------------------------------------------------------------------
  6. IX_TransactionPlantAllocations_Plant
  Gegenrichtung der m:n-Beziehung: welche Lieferungen hat ein Kraftwerk bedient.
------------------------------------------------------------------------------*/
DROP INDEX IF EXISTS IX_TransactionPlantAllocations_Plant ON TransactionPlantAllocations;
CREATE NONCLUSTERED INDEX IX_TransactionPlantAllocations_Plant
    ON TransactionPlantAllocations (PlantID);                -- Suchspalte: Kraftwerk
GO

/*------------------------------------------------------------------------------
  7. IX_GridNodes_Country
  Unterstuetzt die Zuordnung von Netzknoten zu Laendern.
------------------------------------------------------------------------------*/
DROP INDEX IF EXISTS IX_GridNodes_Country ON GridNodes;
CREATE NONCLUSTERED INDEX IX_GridNodes_Country
    ON GridNodes (CountryID);                                -- Suchspalte: Land
GO

/*------------------------------------------------------------------------------
  8. IX_SystemLogs_CreatedAt
  Das Systemprotokoll waechst mit jeder Buchung und jeder Ablehnung.
  Ausgewertet wird es fast immer nach Zeitpunkt, neueste Eintraege zuerst.
------------------------------------------------------------------------------*/
DROP INDEX IF EXISTS IX_SystemLogs_CreatedAt ON SystemLogs;
GO

CREATE NONCLUSTERED INDEX IX_SystemLogs_CreatedAt
    ON SystemLogs (CreatedAt DESC)          -- Suchspalte, neueste zuerst
    INCLUDE (LogLevel);                     -- Deckspalte: erspart den Zugriff auf die Tabelle
GO

/*------------------------------------------------------------------------------
  9. IX_ContractAuditLogs_Contract
  Das Vertragsprotokoll wird fast immer nach Vertrag durchsucht: welche
  Aenderungen gab es an diesem einen Vertrag. Der Zeitpunkt liegt als
  Deckspalte mit im Index.
------------------------------------------------------------------------------*/
DROP INDEX IF EXISTS IX_ContractAuditLogs_Contract ON ContractAuditLogs;
CREATE NONCLUSTERED INDEX IX_ContractAuditLogs_Contract
    ON ContractAuditLogs (ContractID)                        -- Suchspalte: Vertrag
    INCLUDE (ChangedAt);                                     -- Deckspalte: Zeitpunkt
GO

SET STATISTICS IO OFF;                                       -- Messung wieder ausschalten
SET STATISTICS TIME OFF;
GO

/*---------------- Kontrolle: erwartet werden 9 Zeilen, eine davon gefiltert ----------------*/
SELECT  OBJECT_NAME(Index_.object_id) AS Tabelle,
        Index_.name                   AS Index_Name,
        Index_.type_desc              AS Art,
        Index_.has_filter             AS IstGefiltert
FROM sys.indexes AS Index_
INNER JOIN sys.tables AS Systemtabelle ON Systemtabelle.object_id = Index_.object_id      -- nur eigene Tabellen, keine Systemobjekte
WHERE Index_.name LIKE 'IX[_]%' AND Systemtabelle.is_ms_shipped = 0
ORDER BY Tabelle, Index_Name;
GO
