/*==============================================================================
  Projekt : GERDSS - German Energy Export Decision Support System
  Author  : Aileen Hertel
  Datei   : 006-001-spBackupDatenbank_Testskript.sql
  Zweck   : Testskript zur Sicherungsprozedur und Erzeugung der Abgabesicherung
            GERDSS_Backup.bak inklusive Pruefung der Datei.
  Technik : EXEC mit OUTPUT-Parameter, TRY...CATCH, BACKUP DATABASE,
            RESTORE VERIFYONLY, RESTORE HEADERONLY, RESTORE FILELISTONLY

  Hinweis : EINTRAGEN: In beiden Abschnitten den Zielordner an den eigenen Pfad
            anpassen. Der Ordner muss existieren, und der SQL-Server-Dienst
            braucht darauf Schreibrecht.
==============================================================================*/

USE dbGERDSS;
GO

SET ANSI_NULLS ON;                                           -- ISO-Standard fuer NULL-Vergleiche
GO

SET QUOTED_IDENTIFIER ON;                                    -- Erlaubt doppelt gesetzte Bezeichner
GO

/*------------------------------------------------------------------------------
  1. Sicherungsprozedur mit Zeitstempel pruefen
------------------------------------------------------------------------------*/
PRINT '--- Test 1: Sicherung in den Standardordner ---';
DECLARE @Datei NVARCHAR(300);

EXEC dbo.spBackupDatenbank @Dateiname = @Datei OUTPUT;      -- Prozedur mit Rueckgabewert aufrufen

SELECT @Datei AS ErzeugteDatei;                              -- erwartet: Pfad mit Zeitstempel
GO

PRINT '--- Test 2: Protokolleintrag pruefen ---';
SELECT TOP (3) SystemLogID, LogLevel, Message, CreatedAt
FROM SystemLogs
WHERE Message LIKE N'%Sicherung%'
ORDER BY SystemLogID DESC;                                   -- erwartet: INFO-Eintrag
GO

PRINT '--- Test 3: ungueltiger Ordner muss abgefangen werden ---';
BEGIN TRY
    DECLARE @Datei2 NVARCHAR(300);
    EXEC dbo.spBackupDatenbank @Zielordner = N'Z:\gibtesnicht\', @Dateiname = @Datei2 OUTPUT;
    PRINT 'FEHLER: Der Aufruf wurde angenommen.';
END TRY
BEGIN CATCH
    PRINT 'OK - abgefangen: ' + ERROR_MESSAGE();             -- erwartet: Fehlermeldung
END CATCH
GO

SELECT TOP (1) SystemLogID, LogLevel, Message
FROM SystemLogs
WHERE LogLevel = 'ERROR'
ORDER BY SystemLogID DESC;                                   -- erwartet: ERROR-Eintrag
GO

/*------------------------------------------------------------------------------
  2. Abgabesicherung erzeugen und pruefen
------------------------------------------------------------------------------*/
USE master;                                                  -- Sicherung laeuft nicht in der Zieldatenbank
GO

/*---------------- 1. Vollsicherung erstellen ----------------*/
BACKUP DATABASE dbGERDSS
    TO DISK = N'C:\SQL-Kurs\SQL-GERDSS\006-BackUp\GERDSS_Backup.bak'
    WITH INIT,                                               -- vorhandene Datei ueberschreiben
         FORMAT,                                             -- Medium neu beschreiben
         CHECKSUM,                                           -- Pruefsummen mitschreiben
         NAME = N'GERDSS Vollsicherung fuer die Abgabe';
GO

/*---------------- 2. Pruefen, ob die Datei lesbar ist ----------------*/
RESTORE VERIFYONLY
    FROM DISK = N'C:\SQL-Kurs\SQL-GERDSS\006-BackUp\GERDSS_Backup.bak'
    WITH CHECKSUM;                                           -- erwartet: Meldung "Sicherungssatz gueltig"
GO

/*---------------- 3. Kopfdaten der Sicherung ansehen ----------------*/
RESTORE HEADERONLY
    FROM DISK = N'C:\SQL-Kurs\SQL-GERDSS\006-BackUp\GERDSS_Backup.bak';
GO

/*---------------- 4. Enthaltene Dateien ansehen ----------------*/
RESTORE FILELISTONLY
    FROM DISK = N'C:\SQL-Kurs\SQL-GERDSS\006-BackUp\GERDSS_Backup.bak';
GO
