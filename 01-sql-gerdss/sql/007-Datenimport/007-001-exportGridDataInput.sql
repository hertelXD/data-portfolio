/*==============================================================================
  Projekt : GERDSS - German Energy Export Decision Support System
  Author  : Aileen Hertel
  Datei   : 007-001-exportGridDataInput.sql
  Zweck   : Erzeugt die Ausgangsdaten fuer die externe Auswertung:
  freie Kapazitaet je Leitung und Zeitslot, Marktpreise,
  Kreditrahmen und Reservefahrplan.
  Technik : SELECT ueber sechs Tabellen, CROSS JOIN, LEFT JOIN,
  Verwendung der eigenen Skalarwertfunktion sfGetAvailableCapacity
  Ausgabe : Ergebnis markieren -> Rechtsklick -> "Ergebnisse speichern unter"
  -> C:\SQL-Kurs\SQL-GERDSS\007-Datenimport\grid_data_input.csv
==============================================================================*/

USE dbGERDSS;
GO

SELECT  Leitung.LineID,
        Leitung.FromNodeID,
        Leitung.ToNodeID,
        Land.CountryID                                         AS TargetCountryID,
        Land.CountryCode                                       AS TargetCountryCode,
        Reserve.StartTime                                        AS DeliveryTimeSlot,
        dbo.sfGetAvailableCapacity(Leitung.LineID, Reserve.StartTime) AS AvailableCapacityMWh,
        Leitung.LossPercentage,
        Leitung.LengthKM,
        Marktpreis.PricePerMWh,
        Land.CreditLimitEUR,
        Reserve.AvailableReserveMW,
        Reserve.RequiredReserveMW
FROM TransmissionLines AS Leitung
INNER JOIN GridNodes        AS Netzknoten ON Netzknoten.NodeID   = Leitung.ToNodeID
INNER JOIN Countries        AS Land  ON Land.CountryID = Netzknoten.CountryID
CROSS JOIN ReserveSchedules AS Reserve
LEFT  JOIN MarketPrices     AS Marktpreis ON Marktpreis.CountryID = Land.CountryID
                                 AND Marktpreis.TimeSlot  = Reserve.StartTime
WHERE Leitung.IsActive = 1
  AND Reserve.StartTime BETWEEN '2026-08-22T08:00:00' AND '2026-08-22T13:00:00'
ORDER BY Reserve.StartTime, Leitung.LineID;
GO

/*----------------------------------------------------------------------------
  Zusaetzlich: Kraftwerksdaten mit CO2-Faktoren
----------------------------------------------------------------------------*/
SELECT  Kraftwerk.PlantID,
        Kraftwerk.PlantName,
        Kraftwerk.MaxCapacityMW,
        Technologie.TypeName,
        Technologie.CO2EmissionFactor,
        Technologie.IsRenewable
FROM PowerPlants AS Kraftwerk
INNER JOIN PowerPlantTypes AS Technologie ON Technologie.PlantTypeID = Kraftwerk.PlantTypeID
ORDER BY Kraftwerk.PlantID;
GO
