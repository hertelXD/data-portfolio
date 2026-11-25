/*==============================================================================
  Projekt : GERDSS - German Energy Export Decision Support System
  Author  : Aileen Hertel
  Datei   : 001-007-raeumlicheDatenGridNodes.sql
  Zweck   : Ergaenzt die Netzknoten um ihre geografische Lage. Damit laesst sich
            die Entfernung zwischen zwei Knoten aus den Koordinaten berechnen,
            statt sie in LengthKM zu pflegen.
  Technik : ALTER TABLE ADD, Datentyp GEOGRAPHY, geography::Point mit SRID 4326,
            CREATE SPATIAL INDEX ... USING GEOGRAPHY_GRID, STDistance, .Lat/.Long

  Herkunft: Index 8 aus 14_Indexes.sql der Python-Schicht. Dort war der raeumliche
            Index vorbereitet, aber ohne die noetige Spalte wirkungslos. Hier wird
            die Spalte angelegt, gefuellt und indiziert.

  Hinweis : Optional. Die Koordinaten sind Naeherungswerte der Standorte, auf
            zwei Nachkommastellen gerundet. GEOGRAPHY-Spalten koennen nicht als
            Schluesselspalte eines gewoehnlichen Index dienen (Meldung 1978) -
            dafuer gibt es den raeumlichen Index.
==============================================================================*/

USE dbGERDSS;
GO

/*---------------- 1. Spalte anlegen ----------------*/
IF COL_LENGTH('dbo.GridNodes', 'Location') IS NULL
BEGIN
    ALTER TABLE GridNodes ADD Location GEOGRAPHY NULL;      -- NULL, damit vorhandene Zeilen bleiben
END;
GO

/*---------------- 2. Koordinaten setzen ----------------*/
-- geography::Point(Breitengrad, Laengengrad, 4326)
UPDATE GridNodes SET Location = geography::Point(53.55,  9.99, 4326) WHERE NodeName = 'Umspannwerk Nord (DE)';
UPDATE GridNodes SET Location = geography::Point(53.18,  6.99, 4326) WHERE NodeName = 'Grenzknoten NL (NL)';
UPDATE GridNodes SET Location = geography::Point(47.81, 13.04, 4326) WHERE NodeName = 'Grenzknoten AT (AT)';
UPDATE GridNodes SET Location = geography::Point(48.58,  7.75, 4326) WHERE NodeName = 'Grenzknoten FR (FR)';
UPDATE GridNodes SET Location = geography::Point(52.35, 14.55, 4326) WHERE NodeName = 'Grenzknoten PL (PL)';
UPDATE GridNodes SET Location = geography::Point(50.62, 13.73, 4326) WHERE NodeName = 'Grenzknoten CZ (CZ)';
UPDATE GridNodes SET Location = geography::Point(55.05,  9.43, 4326) WHERE NodeName = 'Grenzknoten DK (DK)';
GO

/*---------------- 3. Raeumlicher Index ----------------*/
IF EXISTS (SELECT 1 FROM GridNodes WHERE Location IS NOT NULL)
BEGIN
    DROP INDEX IF EXISTS IX_GridNodes_Location ON GridNodes;

    CREATE SPATIAL INDEX IX_GridNodes_Location
        ON GridNodes (Location)
        USING GEOGRAPHY_GRID;               -- GEOGRAPHY, nicht GEOMETRY: Koordinaten auf der Erdkugel
END;
GO

/*---------------- Kontrolle ----------------*/
SELECT  NodeName,
        Location.Lat        AS Breite,
        Location.Long       AS Laenge,
        Location.ToString() AS Punkt
FROM GridNodes
ORDER BY NodeID;

/*---------------- Entfernung aus den Koordinaten ----------------*/
-- STDistance liefert Meter. Der Vergleich zeigt, wie nah die gepflegte
-- Leitungslaenge an der Luftlinie liegt - eine Leitung ist immer laenger.
SELECT  StartKnoten.NodeName                                    AS VonKnoten,
        ZielKnoten.NodeName                                   AS NachKnoten,
        Leitung.LengthKM                                     AS GepflegtKM,
        ROUND(StartKnoten.Location.STDistance(ZielKnoten.Location) / 1000.0, 1) AS LuftlinieKM
FROM TransmissionLines AS Leitung
INNER JOIN GridNodes AS StartKnoten  ON StartKnoten.NodeID  = Leitung.FromNodeID
INNER JOIN GridNodes AS ZielKnoten ON ZielKnoten.NodeID = Leitung.ToNodeID
WHERE StartKnoten.Location IS NOT NULL AND ZielKnoten.Location IS NOT NULL
ORDER BY LuftlinieKM;
GO
