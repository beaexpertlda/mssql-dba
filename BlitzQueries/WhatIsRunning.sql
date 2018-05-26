--	Query to find what's is running on server
SELECT	s.session_id, 
		DB_NAME(r.database_id) as DBName,
		r.percent_complete,
		[session_status] = s.status,
		[request_status] = r.status,
		[running_command] = r.command,
		[request_wait_type] = r.wait_type, 
		[request_wait_resource] = wait_resource,
		[request_start_time] = r.start_time,
		[request_running_time] = CAST(((DATEDIFF(s,r.start_time,GetDate()))/3600) as varchar) + ' hour(s), '
			+ CAST((DATEDIFF(s,r.start_time,GetDate())%3600)/60 as varchar) + 'min, '
			+ CAST((DATEDIFF(s,r.start_time,GetDate())%60) as varchar) + ' sec',
		[est_time_to_go] = CAST((r.estimated_completion_time/3600000) as varchar) + ' hour(s), '
						+ CAST((r.estimated_completion_time %3600000)/60000  as varchar) + 'min, '
						+ CAST((r.estimated_completion_time %60000)/1000  as varchar) + ' sec',
		[est_completion_time] = dateadd(second,r.estimated_completion_time/1000, getdate()),
		[blocked by] = r.blocking_session_id,
		[statement_text] = Substring(st.TEXT, (r.statement_start_offset / 2) + 1, (
				(
					CASE r.statement_end_offset
						WHEN - 1
							THEN Datalength(st.TEXT)
						ELSE r.statement_end_offset
						END - r.statement_start_offset
					) / 2
				) + 1),
		[Batch_Text] = st.text,
		[WaitTime(S)] = r.wait_time / (1000.0),
		[total_elapsed_time(S)] = r.total_elapsed_time / (1000.0),
		s.login_time, s.host_name, s.host_process_id, s.client_interface_name, s.login_name, 
		s.memory_usage, 
		[session_writes] = s.writes, 
		[request_writes] = r.writes, 
		[session_logical_reads] = s.logical_reads, 
		[request_logical_reads] = r.logical_reads, 
		s.is_user_process, 
		[session_row_count] = s.row_count,
		[request_row_count] = r.row_count,
		r.sql_handle, 
		r.plan_handle, 
		r.open_transaction_count,
		[request_cpu_time] = r.cpu_time,
		[granted_query_memory] = CASE WHEN ((CAST(r.granted_query_memory AS numeric(20,2))*8)/1024/1024) >= 1.0
									  THEN CAST(((CAST(r.granted_query_memory AS numeric(20,2))*8)/1024/1024) AS VARCHAR(23)) + ' GB'
									  WHEN ((CAST(r.granted_query_memory AS numeric(20,2))*8)/1024) >= 1.0
									  THEN CAST(((CAST(r.granted_query_memory AS numeric(20,2))*8)/1024) AS VARCHAR(23)) + ' MB'
									  ELSE CAST((CAST(r.granted_query_memory AS numeric(20,2))*8) AS VARCHAR(23)) + ' KB'
									  END,
		r.query_hash, 
		r.query_plan_hash,
		[BatchQueryPlan] = bqp.query_plan,
		[SqlQueryPlan] = CAST(sqp.query_plan AS xml),
		[program_name] = CASE	WHEN	s.program_name like 'SQLAgent - TSQL JobStep %'
				THEN	(	select	top 1 'SQL Job = '+j.name 
							from msdb.dbo.sysjobs (nolock) as j
							inner join msdb.dbo.sysjobsteps (nolock) AS js on j.job_id=js.job_id
							where right(cast(js.job_id as nvarchar(50)),10) = RIGHT(substring(s.program_name,30,34),10) 
						)
				ELSE	s.program_name
				END,
		[IsSqlJob] = CASE WHEN s.program_name like 'SQLAgent - TSQL JobStep %'THEN 1 ELSE 2	END
FROM	sys.dm_exec_sessions AS s
LEFT JOIN sys.dm_exec_requests AS r ON r.session_id = s.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS st
OUTER APPLY sys.dm_exec_query_plan(r.plan_handle) AS bqp
OUTER APPLY sys.dm_exec_text_query_plan(r.plan_handle,r.statement_start_offset, r.statement_end_offset) as sqp
WHERE	(case	when s.session_id != @@SPID
		AND	(	(	s.session_id > 50
				AND	(	r.session_id IS NOT NULL -- either some part of session has active request
					OR	ISNULL(open_resultset_count,0) > 0 -- some result is open
					)
				)
				OR	s.session_id IN (select ri.blocking_session_id from sys.dm_exec_requests as ri )
			) -- either take user sid, or system sid blocking user sid
				then 1
				when NOT (s.session_id != @@SPID
		AND	(	(	s.session_id > 50
				AND	(	r.session_id IS NOT NULL -- either some part of session has active request
					OR	ISNULL(open_resultset_count,0) > 0 -- some result is open
					)
				)
				OR	s.session_id IN (select ri.blocking_session_id from sys.dm_exec_requests as ri )
			))
				THEN 0
				else null
				end) = 1
		
ORDER BY [IsSqlJob], session_id;
	