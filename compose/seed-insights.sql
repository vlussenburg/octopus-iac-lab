-- compose/seed-insights.sql
--
-- Backfill ~90 days of fake randomquotes deployments into Insights.Deployment
-- (+ matching Insights.Release rows) so the Space → Insights page shows
-- non-trivial deployment-frequency / lead-time / CFR / MTTR curves.
--
-- DEMO ONLY. Never run against an Octopus a customer can see — this fabricates
-- deployment history out of thin air.
--
-- Strategy:
--   * Insights.* is a denormalised projection Octopus writes to async — it has
--     a PK on Id, two non-unique indexes, NO foreign keys, NO triggers
--     (verified on octopusdeploy:latest, 2026.1.x). Inserts here don't touch
--     dbo.Deployment / dbo.ServerTask / dbo.Release at all, so seeding can't
--     corrupt the real deployment record.
--   * We seed ~120 deployments across the last 90 days for project Projects-7
--     (randomquotes) and Spaces-2 (IaC Sandbox), spread over Dev (Environments-2)
--     and Production (Environments-1), tenanted to the three real tenants.
--   * ~7% Failed → CFR > 0. A handful of failure→success pairs within an hour
--     so MTTR has signal. Production deploys have multi-hour
--     (CompletedTime − Release.Assembled) gaps so lead-time isn't flat.
--   * Idempotent: deletes everything with Id LIKE '%-seed-%' first.
--
-- Caveat re Octopus restart: Insights aggregates may be cached in-memory by
-- the server. If the graphs don't refresh after running this, restart with
-- `docker compose -f compose/docker-compose.yml restart octopus` and reload
-- the Insights page.

SET NOCOUNT ON;
SET XACT_ABORT ON;

USE OctopusDeploy;

BEGIN TRANSACTION;

-- Wipe prior seed data so this script is idempotent.
DELETE FROM Insights.Deployment WHERE Id LIKE '%-seed-%';
DELETE FROM Insights.Release    WHERE Id LIKE '%-seed-%';

DECLARE @SpaceId      nvarchar(50) = 'Spaces-2';
DECLARE @ProjectId    nvarchar(50) = 'Projects-7';   -- randomquotes
DECLARE @ChannelId    nvarchar(50) = 'Channels-4';   -- Default channel currently used by randomquotes deployments

-- Resolve env IDs dynamically by slug so a rebuilt lab with different numeric
-- suffixes still works.
DECLARE @EnvDev  nvarchar(50) = (SELECT Id FROM dbo.DeploymentEnvironment WHERE SpaceId=@SpaceId AND Slug='dev');
DECLARE @EnvProd nvarchar(50) = (SELECT Id FROM dbo.DeploymentEnvironment WHERE SpaceId=@SpaceId AND Slug='production');

IF @EnvDev IS NULL OR @EnvProd IS NULL
BEGIN
  ;THROW 50001, 'Could not resolve dev / production env IDs in Spaces-2 — check that control-plane has been applied.', 1;
END

-- Tenant pool (round-robin). Allow NULL for some untenanted deploys.
DECLARE @Tenants TABLE (n int IDENTITY(0,1) PRIMARY KEY, TenantId nvarchar(50) NULL);
INSERT INTO @Tenants(TenantId) VALUES ('Tenants-1'),('Tenants-2'),('Tenants-3'),(NULL);

-- 1) Generate seed releases — one per ~3 days, so deploys cluster on a handful
--    of releases (more realistic than 1 release per deploy).
DECLARE @ReleaseCount int = 30;
DECLARE @i int = 0;
DECLARE @relId       nvarchar(50);
DECLARE @assembled   datetimeoffset;
DECLARE @ver         nvarchar(50);

WHILE @i < @ReleaseCount
BEGIN
  SET @relId     = CONCAT('Releases-seed-', FORMAT(@i, '0000'));
  SET @assembled = DATEADD(DAY, -(90 - (@i * 3)), SYSDATETIMEOFFSET());
  SET @ver       = CONCAT('2.0.', @i, '-seed');

  INSERT INTO Insights.Release (Id, SpaceId, ProjectId, ChannelId, Assembled, Version, Major, Minor, Patch)
  VALUES (@relId, @SpaceId, @ProjectId, @ChannelId, @assembled, @ver, 2, 0, @i);

  SET @i = @i + 1;
END

-- 2) Generate seed deployments. Roughly 120 over 90 days = ~1.3/day average,
--    weighted toward Dev with periodic Prod promotions.
DECLARE @DeployCount int = 120;
DECLARE @j int = 0;

-- Indexes of seeded deployments we'll mark Failed (~7%) and which of those
-- will have a matching success ~20–60min later (MTTR signal). Picked by hand
-- to keep the script deterministic.
DECLARE @failed TABLE (idx int PRIMARY KEY);
INSERT INTO @failed(idx) VALUES (7),(15),(23),(34),(41),(58),(67),(79),(91),(104); -- 10/120 ≈ 8%
DECLARE @recovered TABLE (idx int PRIMARY KEY);
INSERT INTO @recovered(idx) VALUES (7),(15),(34),(58),(79),(104); -- 6 fail→success pairs

DECLARE @depId           nvarchar(50);
DECLARE @daysAgo         float;
DECLARE @completed       datetimeoffset;
DECLARE @envId           nvarchar(50);
DECLARE @relIdx          int;
DECLARE @seedReleaseId   nvarchar(50);
DECLARE @relAssembled    datetimeoffset;
DECLARE @hoursAhead      int;
DECLARE @minutesAhead    int;
DECLARE @durationSec     int;
DECLARE @startTime       datetimeoffset;
DECLARE @queueTime       datetimeoffset;
DECLARE @state           nvarchar(50);
DECLARE @tenantId        nvarchar(50);
DECLARE @recoverDepId    nvarchar(50);
DECLARE @recoverGap      int;
DECLARE @recoverCompleted datetimeoffset;
DECLARE @recoverDuration int;
DECLARE @recoverStart    datetimeoffset;
DECLARE @recoverQueue    datetimeoffset;

WHILE @j < @DeployCount
BEGIN
  SET @depId = CONCAT('Deployments-seed-', FORMAT(@j, '0000'));

  -- Spread across the 90-day window with mild jitter so deploys don't all
  -- land at midnight.
  SET @daysAgo = 90.0 * (1.0 - (@j * 1.0 / @DeployCount))
               + (ABS(CHECKSUM(NEWID())) % 1000) / 1000.0 - 0.5;
  IF @daysAgo < 0 SET @daysAgo = 0;

  SET @completed = DATEADD(SECOND, -CAST(@daysAgo * 86400 AS bigint), SYSDATETIMEOFFSET());

  -- Every 4th deploy is Prod; rest are Dev.
  SET @envId = CASE WHEN @j % 4 = 0 THEN @EnvProd ELSE @EnvDev END;

  -- Walk through releases as time progresses so newer deploys ref newer releases.
  SET @relIdx = (@j * @ReleaseCount) / @DeployCount;
  IF @relIdx >= @ReleaseCount SET @relIdx = @ReleaseCount - 1;
  SET @seedReleaseId = CONCAT('Releases-seed-', FORMAT(@relIdx, '0000'));

  SET @relAssembled = (SELECT Assembled FROM Insights.Release WHERE Id = @seedReleaseId);

  -- Lead time = Completed − Release.Assembled. Clamp both envs so the chart
  -- looks like real CD: Dev 5–125min after release (continuous deploy), Prod
  -- 4–48h after (gated promotion). Without this, @completed floats freely over
  -- the 90-day window and Dev lead-time looks like days.
  IF @envId = @EnvProd
  BEGIN
    SET @hoursAhead = 4 + (ABS(CHECKSUM(NEWID())) % 44);
    SET @completed = DATEADD(HOUR, @hoursAhead, @relAssembled);
  END
  ELSE
  BEGIN
    SET @minutesAhead = 5 + (ABS(CHECKSUM(NEWID())) % 121);
    SET @completed = DATEADD(MINUTE, @minutesAhead, @relAssembled);
  END

  SET @durationSec = 60 + (ABS(CHECKSUM(NEWID())) % 540);
  SET @startTime   = DATEADD(SECOND, -@durationSec, @completed);
  SET @queueTime   = DATEADD(SECOND, -(10 + (ABS(CHECKSUM(NEWID())) % 50)), @startTime);

  SET @state = CASE WHEN EXISTS (SELECT 1 FROM @failed WHERE idx = @j) THEN 'Failed' ELSE 'Success' END;

  SET @tenantId = (SELECT TenantId FROM @Tenants WHERE n = (@j % 4));

  INSERT INTO Insights.Deployment
    (Id, SpaceId, ProjectId, EnvironmentId, ReleaseId, TaskState, CompletedTime,
     HadGuidedFailure, ChannelId, TenantId, QueueTime, StartTime)
  VALUES
    (@depId, @SpaceId, @ProjectId, @envId, @seedReleaseId, @state, @completed,
     0, @ChannelId, @tenantId, @queueTime, @startTime);

  IF EXISTS (SELECT 1 FROM @recovered WHERE idx = @j)
  BEGIN
    SET @recoverDepId     = CONCAT('Deployments-seed-recover-', FORMAT(@j, '0000'));
    SET @recoverGap       = 1200 + (ABS(CHECKSUM(NEWID())) % 2100); -- 20–55min
    SET @recoverCompleted = DATEADD(SECOND, @recoverGap, @completed);
    SET @recoverDuration  = 60 + (ABS(CHECKSUM(NEWID())) % 240);
    SET @recoverStart     = DATEADD(SECOND, -@recoverDuration, @recoverCompleted);
    SET @recoverQueue     = DATEADD(SECOND, -30, @recoverStart);

    INSERT INTO Insights.Deployment
      (Id, SpaceId, ProjectId, EnvironmentId, ReleaseId, TaskState, CompletedTime,
       HadGuidedFailure, ChannelId, TenantId, QueueTime, StartTime)
    VALUES
      (@recoverDepId, @SpaceId, @ProjectId, @envId, @seedReleaseId, 'Success', @recoverCompleted,
       0, @ChannelId, @tenantId, @recoverQueue, @recoverStart);
  END

  SET @j = @j + 1;
END

COMMIT TRANSACTION;

-- Quick sanity readout.
SELECT 'inserted releases'   AS metric, COUNT(*) AS n FROM Insights.Release    WHERE Id LIKE '%-seed-%'
UNION ALL
SELECT 'inserted deploys', COUNT(*)               FROM Insights.Deployment WHERE Id LIKE '%-seed-%'
UNION ALL
SELECT 'failed', COUNT(*)                         FROM Insights.Deployment WHERE Id LIKE '%-seed-%' AND TaskState='Failed'
UNION ALL
SELECT 'prod', COUNT(*)                           FROM Insights.Deployment WHERE Id LIKE '%-seed-%' AND EnvironmentId IN (SELECT Id FROM dbo.DeploymentEnvironment WHERE Slug='production');


--------------------------------------------------------------------------------
-- UNDO — uncomment, save, run via `make seed-insights-undo` (or paste in sqlcmd)
--------------------------------------------------------------------------------
-- USE OctopusDeploy;
-- BEGIN TRANSACTION;
--   DELETE FROM Insights.Deployment WHERE Id LIKE '%-seed-%';
--   DELETE FROM Insights.Release    WHERE Id LIKE '%-seed-%';
-- COMMIT TRANSACTION;
