/*==============================================================================
  Projekt : GERDSS - German Energy Export Decision Support System
  Author  : Aileen Hertel
  Datei   : 002-002-queryVergleichInnerOuterJoin.sql
  Zweck   : Zeigt den Unterschied zwischen innerem und aeusserem Verbund.
            Der aeussere Verbund findet die Potenzialmaerkte, also Laender
            ohne Netzanbindung oder ohne bisherige Lieferung.
  Technik : LEFT OUTER JOIN gegen INNER JOIN, Auswertung der NULL-Werte
            mit CASE, GROUP BY
==============================================================================*/

USE dbGERDSS;
GO

PRINT '--- Mit LEFT OUTER JOIN: alle Importlaender, auch die ohne Anbindung ---';
SELECT  Land.CountryID,
        Land.CountryName,
        Land.CountryCode,
        Land.GridOperator,
        Netzknoten.NodeName             AS Grenzknoten,          -- NULL = kein Knoten vorhanden
        Leitung.LineID,                                       -- NULL = keine Leitung vorhanden
        MAX(Lieferung.DeliveryTimeSlot) AS LetzteLieferung,      -- NULL = nie geliefert
        COUNT(Lieferung.TransactionID)  AS AnzahlLieferungen,
        CASE                                             -- wertet die NULL-Werte fachlich aus
            WHEN Netzknoten.NodeID IS NULL          THEN N'Kein Netzknoten vorhanden'
            WHEN Leitung.LineID IS NULL          THEN N'Knoten ohne Leitungsanbindung'
            WHEN Leitung.IsActive = 0            THEN N'Leitung ausser Betrieb'
            WHEN COUNT(Lieferung.TransactionID) = 0 THEN N'Leitung vorhanden, nie genutzt'
            ELSE N'Aktiver Markt'
        END                     AS Marktstatus
FROM Countries AS Land
LEFT OUTER JOIN GridNodes         AS Netzknoten ON Netzknoten.CountryID = Land.CountryID  -- Laender ohne Knoten bleiben erhalten
LEFT OUTER JOIN TransmissionLines AS Leitung ON Leitung.ToNodeID  = Netzknoten.NodeID    -- Knoten ohne Leitung bleiben erhalten
LEFT OUTER JOIN Transactions      AS Lieferung  ON Lieferung.LineID     = Leitung.LineID    -- Leitungen ohne Lieferung bleiben erhalten
WHERE Land.CountryCode <> 'DE'                                                 -- nur Importlaender betrachten
GROUP BY Land.CountryID, Land.CountryName, Land.CountryCode, Land.GridOperator,
         Netzknoten.NodeID, Netzknoten.NodeName, Leitung.LineID, Leitung.IsActive
ORDER BY Marktstatus, Land.CountryName;
GO

PRINT '--- Zum Vergleich mit INNER JOIN: Laender ohne Anbindung fehlen ---';
SELECT DISTINCT Land.CountryName
FROM Countries AS Land
INNER JOIN GridNodes         AS Netzknoten ON Netzknoten.CountryID = Land.CountryID   -- schliesst Laender ohne Knoten aus
INNER JOIN TransmissionLines AS Leitung ON Leitung.ToNodeID  = Netzknoten.NodeID     -- schliesst Knoten ohne Leitung aus
INNER JOIN Transactions      AS Lieferung  ON Lieferung.LineID     = Leitung.LineID     -- schliesst Leitungen ohne Lieferung aus
WHERE Land.CountryCode <> 'DE'
ORDER BY Land.CountryName;
GO
