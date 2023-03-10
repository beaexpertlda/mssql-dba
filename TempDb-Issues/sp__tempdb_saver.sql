USE [master]
GO

IF OBJECT_ID('master.dbo.sp__tempdb_saver') IS NULL
	EXEC('CREATE PROCEDURE dbo.sp__tempdb_saver AS select 1 as dummy;');
GO

ALTER PROCEDURE [dbo].[sp__tempdb_saver]
(
	 @data_used_pct_threshold tinyint = 90,
	 @kill_spids bit = 0,
	 @retention_days int = 15,
	 @email_recipients varchar(max) = 'sqldba@lab.com',
	 @send_email bit = 0,
	 @verbose tinyint = 1, /* 1 => messages, 2 => messages + table results */
	 @first_x_rows int = 10
)
AS
BEGIN
	/*
		Purpose:	Kill sessions causing tempdb space utilization

		EXEC [dbo].[sp__tempdb_saver] @data_used_pct_threshold = 80, @kill_spids = 1, @verbose = 2, @first_x_rows = 10
	*/
	SET NOCOUNT ON;
	SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
	SET XACT_ABORT ON;
	SET ANSI_WARNINGS OFF;

	DECLARE @sql varchar(8000) = '', @sql_kill varchar(8000),
			@email_body varchar(max) = null,
			@email_subject nvarchar(255) = 'Tempdb Saver: ' + @@SERVERNAME,
			@data_used_pct_current decimal(5,2);

	IF (@verbose > 0)
		PRINT '('+convert(varchar, getdate(), 21)+') Creating table variableS @tempdbspace & @tempdbusage..';
	DECLARE @tempdbspace TABLE (database_name sysname, data_size_mb varchar(100), data_used_mb varchar(100), data_used_pct decimal(5,2), log_size_mb varchar(100), log_used_mb varchar(100), log_used_pct decimal(5,2), version_store_mb decimal(20,2))
	DECLARE @tempdbusage TABLE
	(
		[_td_transaction_date] [datetime] NOT NULL,
		[spid] [smallint] NULL,
		[login_name] [nvarchar](128) NOT NULL,
		[program_name] [nvarchar](128) NULL,
		[host_name] [nvarchar](128) NULL,
		[host_process_id] [int] NULL,
		[is_active_session] [int] NOT NULL,
		[open_transaction_count] [int] NOT NULL,
		[transaction_isolation_level] [varchar](15) NULL,
		[size_bytes] [bigint] NULL,
		[transaction_begin_time] [datetime] NULL,
		[is_snapshot] [int] NOT NULL,
		[log_bytes] [bigint] NULL,
		[log_rsvd] [bigint] NULL,
		[action_taken] [varchar](200) NULL
	);

	IF OBJECT_ID('dba.dbo._hist_tempdb_usage') IS NULL
	BEGIN
		SET @sql = '
		CREATE TABLE dba.dbo._hist_tempdb_usage
		(
		 _td_transaction_date datetime,
		 spid int,
		 login_name sysname,
		 program_name sysname NULL,
		 host_name sysname NULL,
		 host_process_id int,
		 size_bytes bigint,
		 action_taken varchar(100)
		);
		CREATE CLUSTERED INDEX ix_td_transaction_date ON dba.dbo._hist_tempdb_usage(_td_transaction_date);
		'
		IF (@verbose > 0)
		BEGIN
			PRINT '('+convert(varchar, getdate(), 21)+') Creating table dba.dbo._hist_tempdb_usage..'+CHAR(10)+CHAR(13);
			PRINT @sql;
		END

		EXEC (@sql)
	END

	IF (@verbose > 0)
		PRINT '('+convert(varchar, getdate(), 21)+') Populate table @tempdbspace..'	

	INSERT INTO @tempdbspace
	([database_name], data_size_mb, data_used_mb, data_used_pct, log_size_mb, log_used_mb, log_used_pct)
	EXEC tempdb..sp__dbspace;

	UPDATE @tempdbspace
	SET version_store_mb = (SELECT (SUM(version_store_reserved_page_count) / 128.0)	
							FROM tempdb.sys.dm_db_file_space_usage fsu with (nolock));

	IF (@verbose > 1)
	BEGIN
		PRINT '('+convert(varchar, getdate(), 21)+') select * from @tempdbspace..'
		select running_query, t.*
		from @tempdbspace t
		full outer join (values ('@tempdbspace') )dummy(running_query) on 1 = 1;
	END

	IF (@verbose > 0)
		PRINT '('+convert(varchar, getdate(), 21)+') Populate table @tempdbusage..'	
	SET @sql = '
	;WITH T_SnapshotTran
	AS (	
		SELECT	[s_tst].[session_id], --DB_NAME(s_tdt.database_id) as database_name,
				ISNULL(MIN([s_tdt].[database_transaction_begin_time]),MIN(DATEADD(SECOND,snp.elapsed_time_seconds,GETDATE()))) AS [begin_time],
				SUM([s_tdt].[database_transaction_log_bytes_used]) AS [log_bytes],
				SUM([s_tdt].[database_transaction_log_bytes_reserved]) AS [log_rsvd],
				MAX(CASE WHEN snp.elapsed_time_seconds IS NOT NULL THEN 1 ELSE 0 END) AS is_snapshot
		FROM sys.dm_tran_database_transactions [s_tdt]
		JOIN sys.dm_tran_session_transactions [s_tst]
			ON [s_tst].[transaction_id] = [s_tdt].[transaction_id]
		LEFT JOIN sys.dm_tran_active_snapshot_database_transactions snp
			ON snp.session_id = s_tst.session_id AND snp.transaction_id = s_tst.transaction_id
		--WHERE s_tdt.database_id = 2
		GROUP BY [s_tst].[session_id] --,s_tdt.database_id
	)
	,T_TempDbTrans AS 
	(
		SELECT	GETDATE() AS _td_transaction_date,
				des.session_id AS spid,
				des.original_login_name as login_name,  
				des.program_name,
				des.host_name,
				des.host_process_id,
				[is_active_session] = CASE WHEN er.request_id IS NOT NULL THEN 1 ELSE 0 END,
				des.open_transaction_count,
				[transaction_isolation_level] = (CASE des.transaction_isolation_level 
						WHEN 0 THEN ''Unspecified''
						WHEN 1 THEN ''ReadUncommitted''
						WHEN 2 THEN ''ReadCommitted''
						WHEN 3 THEN ''Repeatable''
						WHEN 4 THEN ''Serializable'' 
						WHEN 5 THEN ''Snapshot'' END ),
				[size_bytes] = ((ssu.user_objects_alloc_page_count+ssu.internal_objects_alloc_page_count)-(ssu.internal_objects_dealloc_page_count+ssu.user_objects_dealloc_page_count))*8192,
				[transaction_begin_time] = case when des.open_transaction_count > 0 then (case when ott.begin_time is not null then ott.begin_time when er.start_time is not null then er.start_time else des.last_request_start_time end) else er.start_time end,
				[is_snapshot] = CASE WHEN ISNULL(ott.is_snapshot,0) = 1 THEN 1
									 WHEN tasdt.is_snapshot = 1 THEN 1
									 ELSE ISNULL(ott.is_snapshot,0)
									 END,
				ott.[log_bytes], ott.log_rsvd,
				CONVERT(varchar(200),NULL) AS action_taken
		FROM       sys.dm_exec_sessions des
		LEFT JOIN sys.dm_db_session_space_usage ssu on ssu.session_id = des.session_id
		LEFT JOIN T_SnapshotTran ott ON ott.session_id = ssu.session_id
		LEFT JOIN sys.dm_exec_requests er ON er.session_id = des.session_id
		OUTER APPLY (SELECT ( (tsu.user_objects_alloc_page_count+tsu.internal_objects_alloc_page_count)-(tsu.user_objects_dealloc_page_count+tsu.internal_objects_dealloc_page_count) )*8192 AS size_bytes 
					FROM sys.dm_db_task_space_usage tsu 
					WHERE ((tsu.user_objects_alloc_page_count+tsu.internal_objects_alloc_page_count)-(tsu.user_objects_dealloc_page_count+tsu.internal_objects_dealloc_page_count)) > 0
						AND tsu.session_id = er.session_id
					) as ra
		OUTER APPLY (select 1 as [is_snapshot] from sys.dm_tran_active_snapshot_database_transactions asdt where asdt.session_id = des.session_id) as tasdt
		WHERE des.session_id <> @@SPID --AND (er.request_id IS NOT NULL OR des.open_transaction_count > 0)
			--AND ssu.database_id = 2
	)
	SELECT top ('+CONVERT(varchar,@first_x_rows)+') *
	FROM T_TempDbTrans ot
	WHERE size_bytes > 0 OR is_active_session = 1 OR open_transaction_count > 0 OR  is_snapshot = 1
	'
	IF EXISTS (SELECT * FROM @tempdbspace s WHERE s.version_store_mb >= 0.30*CONVERT(numeric(20,2),data_used_mb))
		SET @sql = @sql + 'order by is_snapshot DESC, transaction_begin_time ASC;'+CHAR(10)
	ELSE
		SET @sql = @sql + 'order by size_bytes desc;'+CHAR(10)
	
	IF (@verbose > 1)
		PRINT @sql
	INSERT @tempdbusage
	EXEC (@sql);

	IF (@verbose > 1)
	BEGIN
		PRINT '('+convert(varchar, getdate(), 21)+') select * from @tempdbusage..'
		
		IF EXISTS (SELECT * FROM @tempdbspace s WHERE s.version_store_mb >= 0.30*CONVERT(numeric(20,2),data_used_mb))
			select running_query, t.*
			from @tempdbusage t
			full outer join (values ('@tempdbusage') )dummy(running_query) on 1 = 1
			order by is_snapshot DESC, transaction_begin_time ASC;
		ELSE
			select running_query, t.* --top (@first_x_rows) 
			from @tempdbusage t
			full outer join (values ('@tempdbusage') )dummy(running_query) on 1 = 1
			order by size_bytes desc;
	END

	IF @verbose > 0
		PRINT '('+convert(varchar, getdate(), 21)+') Compare @tempdbspace.[data_used_pct] with @data_used_pct_threshold ('+convert(varchar,@data_used_pct_threshold)+')..'	
	IF ((SELECT data_used_pct FROM @tempdbspace) > @data_used_pct_threshold)
	BEGIN
		IF @verbose > 0
			PRINT '('+convert(varchar, getdate(), 21)+') Found @tempdbspace.[data_used_pct] > '+convert(varchar,@data_used_pct_threshold)+' %'
			
		IF EXISTS (SELECT * FROM @tempdbspace s WHERE s.version_store_mb >= 0.30*CONVERT(numeric(20,2),data_used_mb)) -- If Version Store Issue
		BEGIN
			IF @verbose > 0
			BEGIN
				PRINT '('+convert(varchar, getdate(), 21)+') Version Store Issue.';
				PRINT '('+convert(varchar, getdate(), 21)+') version_store_mb >= 30% of data_used_mb';
				PRINT '('+convert(varchar, getdate(), 21)+') Pick top spid (@sql_kill) order by ''ORDER BY is_snapshot DESC, transaction_begin_time ASC''';
			END
			SELECT TOP 1 @sql_kill = CONVERT(varchar(30), tu.spid)
			FROM	@tempdbusage tu
			WHERE   host_process_id IS NOT NULL
			AND     login_name NOT IN ('sa', 'NT AUTHORITY\SYSTEM')
			ORDER BY is_snapshot DESC, transaction_begin_time ASC;
		END
		ELSE
		BEGIN -- Not Version Store issue.
			IF @verbose > 0
			BEGIN
				PRINT '('+convert(varchar, getdate(), 21)+') Not Version Store Issue.';
				PRINT '('+convert(varchar, getdate(), 21)+') version_store_mb < 30% of data_used_mb';
				PRINT '('+convert(varchar, getdate(), 21)+') Pick top spid (@sql_kill) order by ''(ISNULL(size_bytes,0)+ISNULL(log_bytes,0)+ISNULL(log_rsvd,0)) DESC''';
			END
			SELECT TOP 1 @sql_kill = CONVERT(varchar(30), tu.spid)
			FROM @tempdbusage tu
			WHERE         host_process_id IS NOT NULL
			AND         login_name NOT IN ('sa', 'NT AUTHORITY\SYSTEM')
			AND size_bytes <> 0
			ORDER BY (ISNULL(size_bytes,0)+ISNULL(log_bytes,0)+ISNULL(log_rsvd,0)) DESC;
		END
		

		IF @verbose > 0
			PRINT '('+convert(varchar, getdate(), 21)+') Top tempdb consumer spid (@sql_kill) = '+@sql_kill;
  
		IF (@sql_kill IS NOT NULL)
		BEGIN
			IF (@kill_spids = 1)
			BEGIN
				IF @verbose > 0
					PRINT '('+convert(varchar, getdate(), 21)+') Kill top consumer.';
				UPDATE @tempdbusage SET action_taken = 'Process Terminated' WHERE spid = @sql_kill
				SET @sql = 'kill ' + @sql_kill;
				PRINT (@sql);
				EXEC (@sql);
				IF @verbose > 0
					PRINT '('+convert(varchar, getdate(), 21)+') Update @tempdbusage with action_taken ''Process Terminated''.';
			END
			ELSE
			BEGIN
				UPDATE @tempdbusage SET action_taken = 'Notified DBA' WHERE spid = @sql_kill
				IF @verbose > 0
					PRINT '('+convert(varchar, getdate(), 21)+') Update @tempdbusage with action_taken ''Notified DBA''.';
			END;

			SET @email_body = 'The following SQL Server process ' + CASE WHEN @kill_spids = 1 THEN 'was' ELSE 'is' END + ' consuming the most tempdb space.' + CHAR(10) + CHAR(10)
			SELECT @data_used_pct_current = data_used_pct FROM @tempdbspace;
			SELECT @email_body = @email_body + 
								'      date_time: ' + CONVERT(varchar(100), _td_transaction_date, 121) + CHAR(10) + 
								'tempdb_used_pct: ' + CONVERT(varchar(100), @data_used_pct_current) + CHAR(10) +
								'           spid: ' + CONVERT(varchar(30), spid) + CHAR(10) +
								'     login_name: ' + login_name + CHAR(10) +
								'   program_name: ' + ISNULL(program_name, '') + CHAR(10) +
								'      host_name: ' + ISNULL(host_name, '') + CHAR(10) +
								'host_process_id: ' + CONVERT(varchar(30), host_process_id) + CHAR(10) +
								'      is_active: ' + CONVERT(varchar(30), is_active_session) + CHAR(10) +
								'     tran_count: ' + CONVERT(varchar(30), open_transaction_count) + CHAR(10) +
								'    is_snapshot: ' + CONVERT(varchar(30), is_snapshot) + CHAR(10) +
								'tran_start_time: ' + CONVERT(varchar(100), transaction_begin_time, 121) + CHAR(10) + 
								'   action_taken: ' + action_taken + CHAR(10) + CHAR(10)
			FROM   @tempdbusage tu
			WHERE spid = @sql_kill;

			PRINT @email_body
			If(@send_email =1)
			BEGIN
				EXEC msdb.dbo.sp_send_dbmail  
					@recipients =  @email_recipients,  
					@subject =     @email_subject,  
					@body =        @email_body,
				@body_format = 'TEXT'
			END
		END;

		IF @verbose > 0
			PRINT '('+convert(varchar, getdate(), 21)+') Populate table dba.dbo._hist_tempdb_usage with top 10 session details.';
		IF EXISTS (SELECT * FROM @tempdbspace s WHERE s.version_store_mb >= 0.30*CONVERT(numeric(20,2),data_used_mb))
			INSERT INTO dba.dbo._hist_tempdb_usage (_td_transaction_date, spid, login_name, program_name, host_name, host_process_id, size_bytes, action_taken)
			SELECT top 10 _td_transaction_date, spid, login_name, program_name, host_name, host_process_id, size_bytes, action_taken
			FROM  @tempdbusage 
			order by is_snapshot DESC, transaction_begin_time ASC;
		ELSE
			INSERT INTO dba.dbo._hist_tempdb_usage (_td_transaction_date, spid, login_name, program_name, host_name, host_process_id, size_bytes, action_taken)
			SELECT top 10 _td_transaction_date, spid, login_name, program_name, host_name, host_process_id, size_bytes, action_taken
			FROM  @tempdbusage 
			order by size_bytes desc;
	END;
	ELSE
	BEGIN
		IF @verbose > 0
			PRINT '('+convert(varchar, getdate(), 21)+') Current tempdb space usage under threshold.'
	END

	IF @verbose > 0
		PRINT '('+convert(varchar, getdate(), 21)+') Purge dba.dbo._hist_tempdb_usage with @retention_days = '+convert(varchar,@retention_days);
	DELETE FROM dba.dbo._hist_tempdb_usage WHERE _td_transaction_date <= DATEADD(day, -@retention_days, GETDATE());

	if @email_body != null
	begin
		SELECT @email_body as Body
	end
END
GO
