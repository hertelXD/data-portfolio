/*==============================================================================
  Projekt : GERDSS - German Energy Export Decision Support System
  Author  : Aileen Hertel
  Datei   : 001-006-insertStammdaten.sql
  Zweck   : Stammdaten der Datenbank. Aufbau in fuenf Abschnitten: Laender,
            Technologien, Netz, Erzeugung, Markt- und Reservedaten.
  Technik : INSERT INTO, INSERT ... SELECT mit VALUES-Konstruktor, NOT EXISTS gegen
            Doppeleintraege, WHILE-Schleife fuer Zeitreihen, Unterabfragen zur
            Ermittlung der Schluesselwerte

  Hinweis : Ueberarbeitet am 26.08.2026. Die Werte sind jetzt so gewaehlt, dass die
            Pruefstufen der Prozedur rechnerisch aufgehen:
            - alle sechs Zielmaerkte haben 24 Stundenpreise (vorher nur vier)
            - der Reservefahrplan hat 24 Stundenfenster (vorher ein Tagesfenster)
            - der Kraftwerkspark deckt die Demo-Lieferung physisch ab
            - Emissionsfaktoren stehen direkt im INSERT statt in einem UPDATE
            Laender, Kreditrahmen und Emissionsfaktoren stammen unveraendert
            aus generate_data.py der Python-Schicht.
==============================================================================*/

USE dbGERDSS;
GO

SET ANSI_NULLS ON;                                           -- ISO-Standard fuer NULL-Vergleiche
GO

SET QUOTED_IDENTIFIER ON;                                    -- Erlaubt doppelt gesetzte Bezeichner
GO

/*------------------------------------------------------------------------------
  1. Laender des Verbundnetzes
------------------------------------------------------------------------------*/

-- Deutschland ist die Quelle. IsExporter sagt aus, ob ein Land selbst
-- exportieren koennte - es ist eine Eigenschaft des Landes, keine Rolle im
-- System. Die Richtung einer Lieferung steckt in TransmissionLines.
INSERT INTO Countries (CountryName, CountryCode, GridOperator, CreditLimitEUR, IsExporter, GridEmissionFactor)
SELECT Werte.CountryName, Werte.CountryCode, Werte.GridOperator, Werte.CreditLimitEUR, Werte.IsExporter, Werte.GridEmissionFactor
FROM (VALUES
        ('Deutschland', 'DE', 'TenneT TSO',        10000000.00, 1, 0.3800),
        ('Niederlande', 'NL', 'TenneT NL',          5000000.00, 0, 0.3500),
        ('Oesterreich', 'AT', 'APG',                3000000.00, 0, 0.1200),
        ('Frankreich',  'FR', 'RTE',                8000000.00, 1, 0.0600),
        ('Polen',       'PL', 'PSE',                4500000.00, 0, 0.7200),
        ('Tschechien',  'CZ', 'CEPS',               3500000.00, 0, 0.5100),
        ('Daenemark',   'DK', 'Energinet',          4000000.00, 1, 0.1500),
        -- Die folgenden vier bewusst OHNE Netzanbindung: sie sind die
        -- Potenzialmaerkte, die der aeussere Verbund in vwInactiveTradeRoutes findet.
        ('Belgien',     'BE', 'Elia',               3800000.00, 0, 0.1800),
        ('Schweiz',     'CH', 'Swissgrid',          6000000.00, 0, 0.0200),
        ('Luxemburg',   'LU', 'Creos Luxembourg',   2000000.00, 0, 0.2500),
        ('Italien',     'IT', 'Terna',              5500000.00, 0, 0.3100)
     ) AS Werte (CountryName, CountryCode, GridOperator, CreditLimitEUR, IsExporter, GridEmissionFactor)
WHERE NOT EXISTS (SELECT 1 FROM Countries AS Land WHERE Land.CountryCode = Werte.CountryCode);
GO

/*------------------------------------------------------------------------------
  2. Erzeugungstechnologien mit CO2-Faktor
------------------------------------------------------------------------------*/

-- Die sechs Technologien entsprechen den Typbezeichnungen der externen
-- Optimierungsschicht (Spalte TypeName in PowerPlants.csv). Nur so lassen sich
-- deren Kraftwerksdaten ohne Umschluesselung uebernehmen.
--
-- Die CO2-Faktoren stammen NICHT aus der CSV: dort steht fuer alle erneuerbaren
-- Technologien 0.0. Auch Wind und Photovoltaik haben aber einen
-- Lebenszyklus-Emissionsfaktor. Mit Nullwerten waeren alle Zielmaerkte gleich
-- sauber und die Emissionsauswertungen ohne Aussage.
INSERT INTO PowerPlantTypes (TypeName, CO2EmissionFactor, IsRenewable)
SELECT Werte.TypeName, Werte.CO2EmissionFactor, Werte.IsRenewable
FROM (VALUES
        ('WindOnshore',  0.0110, 1),
        ('WindOffshore', 0.0120, 1),
        ('Solar',        0.0480, 1),
        ('Hydro',        0.0240, 1),
        ('Gas',          0.3800, 0),
        ('Coal',         0.8500, 0)
     ) AS Werte (TypeName, CO2EmissionFactor, IsRenewable)
WHERE NOT EXISTS (SELECT 1 FROM PowerPlantTypes AS Technologie WHERE Technologie.TypeName = Werte.TypeName);
GO

/*------------------------------------------------------------------------------
  3. Netzknoten und Leitungen
------------------------------------------------------------------------------*/

-- Ein deutscher Einspeiseknoten, dazu je ein Grenzknoten der angebundenen Laender.
INSERT INTO GridNodes (NodeName, CountryID, VoltageLevelIKV)
SELECT Werte.NodeName, Land.CountryID, Werte.VoltageLevelIKV
FROM (VALUES
        ('Umspannwerk Nord (DE)', 'DE', 380.00),
        ('Grenzknoten NL (NL)',   'NL', 380.00),
        ('Grenzknoten AT (AT)',   'AT', 220.00),
        ('Grenzknoten FR (FR)',   'FR', 380.00),
        ('Grenzknoten PL (PL)',   'PL', 380.00),
        ('Grenzknoten CZ (CZ)',   'CZ', 220.00),
        ('Grenzknoten DK (DK)',   'DK', 380.00)
     ) AS Werte (NodeName, CountryCode, VoltageLevelIKV)
INNER JOIN Countries AS Land ON Land.CountryCode = Werte.CountryCode
WHERE NOT EXISTS (SELECT 1 FROM GridNodes AS Netzknoten WHERE Netzknoten.NodeName = Werte.NodeName);
GO

-- Kuppelkapazitaeten in der Groessenordnung der deutschen Grenzkuppelstellen.
-- Oesterreich bleibt bewusst klein (600 MW): daran wird Pruefstufe 1 sichtbar.
INSERT INTO TransmissionLines (FromNodeID, ToNodeID, MaxCapacityMW, LossPercentage, LengthKM, IsActive, BookedMWh)
SELECT  StartKnoten.NodeID, ZielKnoten.NodeID, Werte.MaxCapacityMW, Werte.LossPercentage, Werte.LengthKM, 1, 0.00
FROM (VALUES
        ('Grenzknoten NL (NL)', 5000.00, 2.50, 180.00),
        ('Grenzknoten AT (AT)',  600.00, 1.80, 120.00),
        ('Grenzknoten FR (FR)', 3000.00, 2.80, 220.00),
        ('Grenzknoten PL (PL)', 2000.00, 2.20, 180.00),
        ('Grenzknoten CZ (CZ)', 1500.00, 2.00, 150.00),
        ('Grenzknoten DK (DK)', 2500.00, 2.60, 200.00)
     ) AS Werte (NodeName, MaxCapacityMW, LossPercentage, LengthKM)
INNER JOIN GridNodes AS ZielKnoten ON ZielKnoten.NodeName = Werte.NodeName
CROSS JOIN (SELECT NodeID FROM GridNodes WHERE NodeName = 'Umspannwerk Nord (DE)') AS StartKnoten
WHERE NOT EXISTS (SELECT 1 FROM TransmissionLines AS Leitung
                  WHERE Leitung.FromNodeID = StartKnoten.NodeID AND Leitung.ToNodeID = ZielKnoten.NodeID);
GO

/*------------------------------------------------------------------------------
  4. Kraftwerkspark
------------------------------------------------------------------------------*/

-- Die 150 Anlagen entsprechen Zeile fuer Zeile der Datei PowerPlants.csv der
-- externen Schicht: gleiche IDs, gleiche Namen, gleiche Nennleistung.
--
-- Die PlantID wird ausdruecklich gesetzt, nicht von der IDENTITY-Spalte
-- vergeben. Grund: bei INSERT ... SELECT bestimmt der Abfrageplan die
-- Einfuegereihenfolge, nicht die Reihenfolge der VALUES-Liste. Die Nummern
-- wuerden dann nach Technologie gruppiert vergeben und nicht mehr zu den IDs
-- der Datei passen. Beide Seiten muessen aber dieselben Kraftwerksnummern
-- verwenden, sonst laufen die importierten Zuteilungen ins Leere.
SET IDENTITY_INSERT dbo.PowerPlants ON;

INSERT INTO PowerPlants (PlantID, PlantName, PlantTypeID, MaxCapacityMW, NodeID)
SELECT Werte.PlantID, Werte.PlantName, Technologie.PlantTypeID, Werte.MaxCapacityMW, Einspeiseknoten.NodeID
FROM (VALUES
        (1, 'DE-Grid-WindOnshore-001', 'WindOnshore', 570.92),
        (2, 'DE-Grid-WindOffshore-002', 'WindOffshore', 363.21),
        (3, 'DE-Grid-Solar-003', 'Solar', 102.04),
        (4, 'DE-Grid-Solar-004', 'Solar', 521.04),
        (5, 'DE-Grid-WindOffshore-005', 'WindOffshore', 427.76),
        (6, 'DE-Grid-Solar-006', 'Solar', 582.25),
        (7, 'DE-Grid-Hydro-007', 'Hydro', 135.28),
        (8, 'DE-Grid-Solar-008', 'Solar', 118.21),
        (9, 'DE-Grid-Solar-009', 'Solar', 319.61),
        (10, 'DE-Grid-WindOnshore-010', 'WindOnshore', 181.83),
        (11, 'DE-Grid-WindOffshore-011', 'WindOffshore', 92.3),
        (12, 'DE-Grid-Solar-012', 'Solar', 226.15),
        (13, 'DE-Grid-WindOnshore-013', 'WindOnshore', 473.25),
        (14, 'DE-Grid-Solar-014', 'Solar', 313.4),
        (15, 'DE-Grid-WindOnshore-015', 'WindOnshore', 37.41),
        (16, 'DE-Grid-WindOffshore-016', 'WindOffshore', 110.61),
        (17, 'DE-Grid-Solar-017', 'Solar', 569.84),
        (18, 'DE-Grid-Coal-018', 'Coal', 486.95),
        (19, 'DE-Grid-Solar-019', 'Solar', 67.63),
        (20, 'DE-Grid-WindOffshore-020', 'WindOffshore', 269.69),
        (21, 'DE-Grid-Solar-021', 'Solar', 302.15),
        (22, 'DE-Grid-Solar-022', 'Solar', 546.5),
        (23, 'DE-Grid-Solar-023', 'Solar', 400.89),
        (24, 'DE-Grid-Solar-024', 'Solar', 316.84),
        (25, 'DE-Grid-WindOnshore-025', 'WindOnshore', 119.06),
        (26, 'DE-Grid-Coal-026', 'Coal', 467.33),
        (27, 'DE-Grid-Gas-027', 'Gas', 537.95),
        (28, 'DE-Grid-WindOnshore-028', 'WindOnshore', 553.91),
        (29, 'DE-Grid-Solar-029', 'Solar', 125.63),
        (30, 'DE-Grid-Solar-030', 'Solar', 201.94),
        (31, 'DE-Grid-WindOnshore-031', 'WindOnshore', 170.1),
        (32, 'DE-Grid-Hydro-032', 'Hydro', 220.48),
        (33, 'DE-Grid-Solar-033', 'Solar', 330.19),
        (34, 'DE-Grid-Solar-034', 'Solar', 483.3),
        (35, 'DE-Grid-Solar-035', 'Solar', 592.26),
        (36, 'DE-Grid-Hydro-036', 'Hydro', 127.24),
        (37, 'DE-Grid-Solar-037', 'Solar', 491.12),
        (38, 'DE-Grid-WindOffshore-038', 'WindOffshore', 440.11),
        (39, 'DE-Grid-Hydro-039', 'Hydro', 53.69),
        (40, 'DE-Grid-WindOnshore-040', 'WindOnshore', 78.36),
        (41, 'DE-Grid-Gas-041', 'Gas', 377.75),
        (42, 'DE-Grid-Solar-042', 'Solar', 47.5),
        (43, 'DE-Grid-Solar-043', 'Solar', 201.86),
        (44, 'DE-Grid-WindOffshore-044', 'WindOffshore', 386.16),
        (45, 'DE-Grid-Gas-045', 'Gas', 288.61),
        (46, 'DE-Grid-Solar-046', 'Solar', 430.81),
        (47, 'DE-Grid-Hydro-047', 'Hydro', 341.15),
        (48, 'DE-Grid-Hydro-048', 'Hydro', 301.34),
        (49, 'DE-Grid-WindOnshore-049', 'WindOnshore', 262.25),
        (50, 'DE-Grid-Solar-050', 'Solar', 73.66),
        (51, 'DE-Grid-Solar-051', 'Solar', 385.48),
        (52, 'DE-Grid-Solar-052', 'Solar', 310.06),
        (53, 'DE-Grid-Gas-053', 'Gas', 157.08),
        (54, 'DE-Grid-WindOnshore-054', 'WindOnshore', 455.78),
        (55, 'DE-Grid-Solar-055', 'Solar', 55.42),
        (56, 'DE-Grid-Solar-056', 'Solar', 105.12),
        (57, 'DE-Grid-Gas-057', 'Gas', 486.79),
        (58, 'DE-Grid-WindOffshore-058', 'WindOffshore', 524.16),
        (59, 'DE-Grid-Hydro-059', 'Hydro', 120.08),
        (60, 'DE-Grid-Gas-060', 'Gas', 328.21),
        (61, 'DE-Grid-Hydro-061', 'Hydro', 538.69),
        (62, 'DE-Grid-Solar-062', 'Solar', 74.93),
        (63, 'DE-Grid-Solar-063', 'Solar', 261.99),
        (64, 'DE-Grid-Hydro-064', 'Hydro', 517.83),
        (65, 'DE-Grid-Solar-065', 'Solar', 311.34),
        (66, 'DE-Grid-WindOnshore-066', 'WindOnshore', 141.04),
        (67, 'DE-Grid-Solar-067', 'Solar', 209.19),
        (68, 'DE-Grid-Gas-068', 'Gas', 200.69),
        (69, 'DE-Grid-WindOnshore-069', 'WindOnshore', 424.78),
        (70, 'DE-Grid-WindOnshore-070', 'WindOnshore', 583.35),
        (71, 'DE-Grid-Coal-071', 'Coal', 158.55),
        (72, 'DE-Grid-WindOnshore-072', 'WindOnshore', 187.52),
        (73, 'DE-Grid-Solar-073', 'Solar', 31.76),
        (74, 'DE-Grid-WindOffshore-074', 'WindOffshore', 306.58),
        (75, 'DE-Grid-Solar-075', 'Solar', 174.4),
        (76, 'DE-Grid-Gas-076', 'Gas', 151.34),
        (77, 'DE-Grid-Solar-077', 'Solar', 298.78),
        (78, 'DE-Grid-Coal-078', 'Coal', 152.81),
        (79, 'DE-Grid-WindOffshore-079', 'WindOffshore', 459.36),
        (80, 'DE-Grid-Solar-080', 'Solar', 439.65),
        (81, 'DE-Grid-WindOnshore-081', 'WindOnshore', 383.06),
        (82, 'DE-Grid-WindOffshore-082', 'WindOffshore', 326.11),
        (83, 'DE-Grid-Solar-083', 'Solar', 502.83),
        (84, 'DE-Grid-Solar-084', 'Solar', 120.05),
        (85, 'DE-Grid-Solar-085', 'Solar', 358.63),
        (86, 'DE-Grid-WindOffshore-086', 'WindOffshore', 19.79),
        (87, 'DE-Grid-WindOnshore-087', 'WindOnshore', 143.63),
        (88, 'DE-Grid-WindOffshore-088', 'WindOffshore', 112.88),
        (89, 'DE-Grid-WindOffshore-089', 'WindOffshore', 238.17),
        (90, 'DE-Grid-Gas-090', 'Gas', 91.14),
        (91, 'DE-Grid-Solar-091', 'Solar', 76.95),
        (92, 'DE-Grid-Gas-092', 'Gas', 527.63),
        (93, 'DE-Grid-Solar-093', 'Solar', 399.39),
        (94, 'DE-Grid-Hydro-094', 'Hydro', 337.57),
        (95, 'DE-Grid-WindOnshore-095', 'WindOnshore', 152.69),
        (96, 'DE-Grid-Solar-096', 'Solar', 539.36),
        (97, 'DE-Grid-Gas-097', 'Gas', 383.53),
        (98, 'DE-Grid-Solar-098', 'Solar', 216.03),
        (99, 'DE-Grid-WindOffshore-099', 'WindOffshore', 539.3),
        (100, 'DE-Grid-Gas-100', 'Gas', 470.13),
        (101, 'DE-Grid-WindOffshore-101', 'WindOffshore', 59.64),
        (102, 'DE-Grid-Solar-102', 'Solar', 540.15),
        (103, 'DE-Grid-WindOffshore-103', 'WindOffshore', 15.43),
        (104, 'DE-Grid-Solar-104', 'Solar', 401.47),
        (105, 'DE-Grid-Solar-105', 'Solar', 104.88),
        (106, 'DE-Grid-WindOnshore-106', 'WindOnshore', 418.22),
        (107, 'DE-Grid-WindOffshore-107', 'WindOffshore', 142.32),
        (108, 'DE-Grid-WindOffshore-108', 'WindOffshore', 149.98),
        (109, 'DE-Grid-Solar-109', 'Solar', 450.43),
        (110, 'DE-Grid-WindOffshore-110', 'WindOffshore', 511.04),
        (111, 'DE-Grid-WindOffshore-111', 'WindOffshore', 345.3),
        (112, 'DE-Grid-Solar-112', 'Solar', 226.95),
        (113, 'DE-Grid-Solar-113', 'Solar', 153.95),
        (114, 'DE-Grid-Coal-114', 'Coal', 241.93),
        (115, 'DE-Grid-Gas-115', 'Gas', 382.37),
        (116, 'DE-Grid-Hydro-116', 'Hydro', 306.56),
        (117, 'DE-Grid-WindOnshore-117', 'WindOnshore', 300.59),
        (118, 'DE-Grid-Solar-118', 'Solar', 436.25),
        (119, 'DE-Grid-Solar-119', 'Solar', 24.35),
        (120, 'DE-Grid-WindOffshore-120', 'WindOffshore', 114.5),
        (121, 'DE-Grid-Gas-121', 'Gas', 572.82),
        (122, 'DE-Grid-Gas-122', 'Gas', 228.39),
        (123, 'DE-Grid-Solar-123', 'Solar', 557.71),
        (124, 'DE-Grid-WindOnshore-124', 'WindOnshore', 580.33),
        (125, 'DE-Grid-Coal-125', 'Coal', 513.28),
        (126, 'DE-Grid-Solar-126', 'Solar', 237.21),
        (127, 'DE-Grid-Gas-127', 'Gas', 196.98),
        (128, 'DE-Grid-Solar-128', 'Solar', 338.51),
        (129, 'DE-Grid-Gas-129', 'Gas', 420.66),
        (130, 'DE-Grid-WindOnshore-130', 'WindOnshore', 67.33),
        (131, 'DE-Grid-WindOffshore-131', 'WindOffshore', 594.13),
        (132, 'DE-Grid-Solar-132', 'Solar', 315.81),
        (133, 'DE-Grid-Gas-133', 'Gas', 447.05),
        (134, 'DE-Grid-WindOffshore-134', 'WindOffshore', 424.47),
        (135, 'DE-Grid-WindOnshore-135', 'WindOnshore', 183.22),
        (136, 'DE-Grid-Hydro-136', 'Hydro', 487.97),
        (137, 'DE-Grid-Gas-137', 'Gas', 548.81),
        (138, 'DE-Grid-WindOnshore-138', 'WindOnshore', 305.89),
        (139, 'DE-Grid-Hydro-139', 'Hydro', 393.48),
        (140, 'DE-Grid-WindOffshore-140', 'WindOffshore', 479.52),
        (141, 'DE-Grid-Gas-141', 'Gas', 209.42),
        (142, 'DE-Grid-WindOnshore-142', 'WindOnshore', 65.45),
        (143, 'DE-Grid-WindOnshore-143', 'WindOnshore', 31.21),
        (144, 'DE-Grid-WindOnshore-144', 'WindOnshore', 330.16),
        (145, 'DE-Grid-Solar-145', 'Solar', 358.59),
        (146, 'DE-Grid-Solar-146', 'Solar', 32.04),
        (147, 'DE-Grid-Hydro-147', 'Hydro', 222.51),
        (148, 'DE-Grid-Solar-148', 'Solar', 318.12),
        (149, 'DE-Grid-Hydro-149', 'Hydro', 137.33),
        (150, 'DE-Grid-WindOffshore-150', 'WindOffshore', 60.36)
     ) AS Werte (PlantID, PlantName, TypeName, MaxCapacityMW)
INNER JOIN PowerPlantTypes AS Technologie ON Technologie.TypeName = Werte.TypeName
CROSS JOIN (SELECT NodeID FROM GridNodes WHERE NodeName = 'Umspannwerk Nord (DE)') AS Einspeiseknoten
WHERE NOT EXISTS (SELECT 1 FROM PowerPlants AS Kraftwerk WHERE Kraftwerk.PlantID = Werte.PlantID);

SET IDENTITY_INSERT dbo.PowerPlants OFF;
GO

/*------------------------------------------------------------------------------
  5. Vertraege, Marktpreise, Reservefahrplan
------------------------------------------------------------------------------*/

-- Rahmenvertraege. Wo keiner besteht, greift der Marktpreis des Ziellandes.
INSERT INTO ExportContracts (ExporterCountryID, ImporterCountryID, ContractStartDate, ContractEndDate, AgreedPricePerMWh)
SELECT  Exportland.CountryID, Zielland.CountryID, '2026-01-01 00:00:00', Werte.Ende, Werte.Preis
FROM (VALUES
        ('NL', '2026-12-31 23:59:59', 85.50),
        ('AT', NULL,                  90.00),
        ('FR', NULL,                  88.00),
        ('PL', NULL,                  97.50)
     ) AS Werte (CountryCode, Ende, Preis)
INNER JOIN Countries AS Zielland ON Zielland.CountryCode = Werte.CountryCode
CROSS JOIN (SELECT CountryID FROM Countries WHERE CountryCode = 'DE') AS Exportland
WHERE NOT EXISTS (SELECT 1 FROM ExportContracts AS Vertrag WHERE Vertrag.ImporterCountryID = Zielland.CountryID);
GO

-- Marktpreise: 24 Stundenwerte je angebundenem Zielland, tagsueber teurer.
-- Ein schmutzigeres Netz zahlt einen Aufschlag - das macht die Zielauswahl
-- der Optimierung nachvollziehbar.
DECLARE @h INT = 0;
DECLARE @Tag DATETIME2(0) = '2026-08-22T00:00:00';

WHILE @h < 24
BEGIN
    INSERT INTO MarketPrices (TimeSlot, CountryID, PricePerMWh)
    SELECT  DATEADD(HOUR, @h, @Tag),
            Land.CountryID,
            CASE WHEN @h BETWEEN 8 AND 19 THEN 95.00 ELSE 62.00 END
            + (Land.GridEmissionFactor * 10)
    FROM Countries AS Land
    WHERE Land.CountryCode IN ('NL', 'AT', 'FR', 'PL', 'CZ', 'DK')   -- die sechs angebundenen Zielmaerkte
      AND NOT EXISTS (SELECT 1 FROM MarketPrices AS Marktpreis
                      WHERE Marktpreis.CountryID = Land.CountryID
                        AND Marktpreis.TimeSlot  = DATEADD(HOUR, @h, @Tag));
    SET @h = @h + 1;
END
GO

-- Reservefahrplan: 24 Stundenfenster statt eines Tagesfensters. Erst dadurch
-- greift die Unterscheidung zwischen Mittags- und Randstunden, und erst
-- dadurch ist der Ueberlappungsschutz trPreventReserveOverlap vorfuehrbar.
-- Je exportierter Leistung sind 15 Prozent zusaetzlich vorzuhalten: bei
-- 5000 MW sind das 750 MW. Die freie Reserve muss darueber liegen.
DECLARE @s INT = 0;
DECLARE @Basis DATETIME2(0) = '2026-08-22T00:00:00';

WHILE @s < 24
BEGIN
    INSERT INTO ReserveSchedules (StartTime, EndTime, AvailableReserveMW, RequiredReserveMW)
    SELECT  DATEADD(HOUR, @s, @Basis),
            DATEADD(HOUR, @s + 1, @Basis),
            CASE WHEN @s BETWEEN 10 AND 15 THEN 1000.00    -- Mittagsstunden: weniger vorgehalten
                 ELSE 2500.00 END,
            500.00                                          -- gesetzliches Minimum
    WHERE NOT EXISTS (SELECT 1 FROM ReserveSchedules AS Reserve
                      WHERE Reserve.StartTime = DATEADD(HOUR, @s, @Basis));
    SET @s = @s + 1;
END
GO

/*------------------------------------------------------------------------------
  Kontrolle
------------------------------------------------------------------------------*/
SELECT 'Countries'         AS Tabelle, COUNT(*) AS Zeilen FROM Countries      -- erwartet:  11
UNION ALL SELECT 'PowerPlantTypes',   COUNT(*) FROM PowerPlantTypes           -- erwartet:   6
UNION ALL SELECT 'GridNodes',         COUNT(*) FROM GridNodes                 -- erwartet:   7
UNION ALL SELECT 'PowerPlants',       COUNT(*) FROM PowerPlants               -- erwartet: 150
UNION ALL SELECT 'TransmissionLines', COUNT(*) FROM TransmissionLines         -- erwartet:   6
UNION ALL SELECT 'ExportContracts',   COUNT(*) FROM ExportContracts           -- erwartet:   4
UNION ALL SELECT 'MarketPrices',      COUNT(*) FROM MarketPrices              -- erwartet: 144
UNION ALL SELECT 'ReserveSchedules',  COUNT(*) FROM ReserveSchedules;         -- erwartet:  24
GO

-- Vergebene Kraftwerks-IDs. Sie muessen mit der Spalte PlantID in
-- PowerPlants.csv uebereinstimmen: 1 bis 150, lueckenlos.
SELECT MIN(PlantID) AS ErsteID, MAX(PlantID) AS LetzteID, COUNT(*) AS Anzahl
FROM PowerPlants;                                            -- erwartet: 1 / 150 / 150

-- Stichprobe gegen die Datei. Erwartet:
--    1 DE-Grid-WindOnshore-001    570.92
--    2 DE-Grid-WindOffshore-002   363.21
--    3 DE-Grid-Solar-003          102.04
--  149 DE-Grid-Hydro-149          137.33
--  150 DE-Grid-WindOffshore-150    60.36
SELECT PlantID, PlantName, MaxCapacityMW FROM PowerPlants
WHERE PlantID IN (1, 2, 3, 149, 150) ORDER BY PlantID;
GO

-- Erneuerbare Nennleistung: muss ueber der groessten Demo-Lieferung liegen.
SELECT SUM(Kraftwerk.MaxCapacityMW) AS ErneuerbarMW                                   -- erwartet: 35688.02
FROM PowerPlants AS Kraftwerk
INNER JOIN PowerPlantTypes AS Technologie ON Technologie.PlantTypeID = Kraftwerk.PlantTypeID
WHERE Technologie.IsRenewable = 1;
GO

SELECT  Leitung.LineID, Land.CountryName AS Zielland, Leitung.MaxCapacityMW, Leitung.BookedMWh
FROM TransmissionLines AS Leitung
INNER JOIN GridNodes AS Netzknoten ON Netzknoten.NodeID   = Leitung.ToNodeID
INNER JOIN Countries AS Land  ON Land.CountryID = Netzknoten.CountryID
ORDER BY Leitung.MaxCapacityMW DESC;
GO

/*==============================================================================
  Was danach durchlaeuft und was nicht

  Lieferung 5000 MWh nach NL, Slot 12:00
      Stufe 1  Leitung 5000 MW frei          -> passt genau
      Stufe 2  rund 427.500 EUR gegen 5 Mio  -> passt
      Stufe 3  750 MW noetig, 1500 MW frei   -> passt
      Erzeugung 5000 von 35688 MW erneuerbar -> physisch gedeckt

  Dieselbe Lieferung nach AT      -> Stufe 1 lehnt ab (nur 600 MW)
  Zweite Lieferung NL im selben Slot -> Stufe 1 lehnt ab (nichts mehr frei)
==============================================================================*/
