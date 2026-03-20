-- File Name: awr_top_sql_last_day.sql
-- Purpose: Collect top-N SQL by CPU from AWR for the last day; output SQL text,
--          plan, v$sql/v$sqlstats, and object/table/index info per SQL_ID via DBMS_OUTPUT. No DDL.
-- Created: 20260311 by huangtingzhong


SET SERVEROUTPUT ON

DECLARE
    v_days      NUMBER        := 1;     -- 最近 N 天
    v_top_n     NUMBER        := 10;    -- 每天取 TOP N 个 SQL_ID（按 CPU）
    v_sql_id    VARCHAR2(64);
    v_line      VARCHAR2(32767);
    v_count     NUMBER := 0;

    -- 对象 (owner, name) 记录与集合，用于替代 GTT
    TYPE t_obj_rec IS RECORD (obj_owner VARCHAR2(128), obj_name VARCHAR2(128));
    TYPE t_obj_tab IS TABLE OF t_obj_rec;
    TYPE t_idx_rec IS RECORD (owner VARCHAR2(128), index_name VARCHAR2(128), status VARCHAR2(20), partitioned VARCHAR2(3));
    TYPE t_idx_tab IS TABLE OF t_idx_rec;
    plan_objs    t_obj_tab := t_obj_tab();
    table_objs   t_obj_tab := t_obj_tab();
    table_objs_idx t_obj_tab := t_obj_tab();
    index_objs   t_idx_tab := t_idx_tab();
    full_seg_objs t_obj_tab := t_obj_tab();
    in_list_plan   VARCHAR2(32767);
    in_list_table  VARCHAR2(32767);
    in_list_index  VARCHAR2(32767);
    in_list_seg    VARCHAR2(32767);

    -- 最近一天 TOP SQL（按 CPU），去重 SQL_ID
    CURSOR c_top_sql IS
        WITH snap_range AS (
            SELECT MIN(s.SNAP_ID) AS bid,
                   MAX(s.SNAP_ID) AS eid,
                   MAX(s.DBID) AS DBID,
                   MAX(s.INSTANCE_NUMBER) AS INSTANCE_NUMBER
            FROM SYS.WRM$_SNAPSHOT s
            WHERE s.INSTANCE_NUMBER = (SELECT instance_number FROM v$instance)
              AND TRUNC(s.BEGIN_INTERVAL_TIME) >= TRUNC(SYSDATE) - v_days
        ),
        agg AS (
            SELECT d.SQL_ID,
                   SUM(d.CPU_TIME_DELTA)     AS cput,
                   SUM(d.ELAPSED_TIME_DELTA) AS elap,
                   SUM(d.EXECUTIONS_DELTA)   AS execs,
                   SUM(d.BUFFER_GETS_DELTA)  AS bget
            FROM SYS.WRH$_SQLSTAT d
            JOIN snap_range sr ON d.SNAP_ID > sr.bid AND d.SNAP_ID <= sr.eid
             AND d.DBID = sr.DBID AND d.INSTANCE_NUMBER = sr.INSTANCE_NUMBER
            GROUP BY d.SQL_ID
            HAVING NVL(SUM(d.CPU_TIME_DELTA), 0) > 0 OR NVL(SUM(d.BUFFER_GETS_DELTA), 0) > 0
        ),
        rn AS (
            SELECT SQL_ID,
                   ROW_NUMBER() OVER (ORDER BY cput DESC NULLS LAST, SQL_ID) AS rk
            FROM agg
        )
        SELECT SQL_ID FROM rn WHERE rk <= v_top_n;

    -- 单段不超过 4000 字符，避免 YashanDB DBMS_OUTPUT 报 YAS-04412（buffer size is too small）
    PROCEDURE put_line(s VARCHAR2) IS
        v_max NUMBER := 4000;
        v_len NUMBER;
        v_off NUMBER := 1;
    BEGIN
        IF s IS NULL THEN DBMS_OUTPUT.PUT_LINE(''); RETURN; END IF;
        v_len := LENGTH(s);
        WHILE v_off <= v_len LOOP
            DBMS_OUTPUT.PUT_LINE(SUBSTR(s, v_off, v_max));
            v_off := v_off + v_max;
        END LOOP;
    END;

    -- 数值格式：<1000 保留 2 位小数，<10000 为 K，否则为 W
    FUNCTION fmt_num_kw(p_val NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p_val IS NULL THEN RETURN NULL; END IF;
        IF p_val < 1000 THEN RETURN TO_CHAR(ROUND(p_val, 2)); END IF;
        IF p_val < 10000 THEN RETURN TO_CHAR(ROUND(p_val/1000, 2)) || 'K'; END IF;
        RETURN TO_CHAR(ROUND(p_val/10000, 2)) || 'W';
    END fmt_num_kw;

    -- 时间格式：输入为微秒，输出 ms/s/m/h
    FUNCTION fmt_time_us(p_us NUMBER) RETURN VARCHAR2 IS
        v_ms NUMBER;
    BEGIN
        IF p_us IS NULL THEN RETURN NULL; END IF;
        v_ms := p_us / 1000;
        IF v_ms < 1000 THEN RETURN ROUND(v_ms, 2) || 'ms'; END IF;
        IF v_ms/60 < 60 THEN RETURN ROUND(v_ms/60, 2) || 's'; END IF;
        IF v_ms/60/60 < 60 THEN RETURN ROUND(v_ms/60/60, 2) || 'm'; END IF;
        RETURN ROUND(v_ms/60/60/60, 2) || 'h';
    END fmt_time_us;

BEGIN
    DBMS_OUTPUT.ENABLE(1000000);
    DBMS_OUTPUT.PUT_LINE('collect_top_sql: start, v_top_n=' || v_top_n);

    FOR rec IN c_top_sql LOOP
        v_sql_id := rec.SQL_ID;
        v_count  := v_count + 1;
        DBMS_OUTPUT.PUT_LINE('Processing SQL_ID: ' || v_sql_id);

        -- YashanDB：集合变量先初始化再 BULK COLLECT/EXTEND，避免 uninitialized varray
        plan_objs    := t_obj_tab();
        table_objs   := t_obj_tab();
        table_objs_idx := t_obj_tab();
        index_objs   := t_idx_tab();
        full_seg_objs := t_obj_tab();

        -- 优化：每个 SQL_ID 只查一次 V$SQL_PLAN / dba_indexes，结果放入 PL/SQL 集合，后续用动态 SQL IN 列表复用
        SELECT DISTINCT OBJECT_OWNER, OBJECT_NAME
          BULK COLLECT INTO plan_objs
          FROM V$SQL_PLAN
         WHERE SQL_ID = v_sql_id AND OBJECT_NAME IS NOT NULL;

        in_list_plan := '(NULL,NULL)';
        IF plan_objs IS NOT NULL AND plan_objs.COUNT > 0 THEN
            in_list_plan := '';
            FOR i IN 1..plan_objs.COUNT LOOP
                IF i > 1 THEN in_list_plan := in_list_plan || ','; END IF;
                in_list_plan := in_list_plan || '(''' || REPLACE(plan_objs(i).obj_owner, '''', '''''') || ''',''' || REPLACE(plan_objs(i).obj_name, '''', '''''') || ''')';
            END LOOP;
        END IF;
        EXECUTE IMMEDIATE
            'SELECT DISTINCT table_owner, table_name FROM dba_indexes WHERE (owner, index_name) IN (' || in_list_plan || ')'
            BULK COLLECT INTO table_objs_idx;
        table_objs := table_objs_idx;
        FOR i IN 1..plan_objs.COUNT LOOP
            DECLARE
                found BOOLEAN := FALSE;
            BEGIN
                FOR j IN 1..table_objs.COUNT LOOP
                    IF table_objs(j).obj_owner = plan_objs(i).obj_owner AND table_objs(j).obj_name = plan_objs(i).obj_name THEN
                        found := TRUE; EXIT;
                    END IF;
                END LOOP;
                IF NOT found THEN
                    table_objs.EXTEND(1);
                    table_objs(table_objs.COUNT).obj_owner := plan_objs(i).obj_owner;
                    table_objs(table_objs.COUNT).obj_name  := plan_objs(i).obj_name;
                END IF;
            END;
        END LOOP;
        in_list_table := '(NULL,NULL)';
        IF table_objs IS NOT NULL AND table_objs.COUNT > 0 THEN
            in_list_table := '';
            FOR i IN 1..table_objs.COUNT LOOP
                IF i > 1 THEN in_list_table := in_list_table || ','; END IF;
                in_list_table := in_list_table || '(''' || REPLACE(table_objs(i).obj_owner, '''', '''''') || ''',''' || REPLACE(table_objs(i).obj_name, '''', '''''') || ''')';
            END LOOP;
        END IF;
        EXECUTE IMMEDIATE
            'SELECT i.OWNER, i.INDEX_NAME, i.status, i.PARTITIONED FROM DBA_INDEXES i WHERE (i.TABLE_OWNER, i.TABLE_NAME) IN (' || in_list_table || ') AND i.status NOT IN (''VALID'')'
            BULK COLLECT INTO index_objs;
        in_list_index := NULL;
        FOR ix IN 1..NVL(index_objs.COUNT, 0) LOOP
            IF index_objs(ix).partitioned = 'YES' THEN
                IF in_list_index IS NOT NULL THEN in_list_index := in_list_index || ','; END IF;
                in_list_index := NVL(in_list_index, '') || '(''' || REPLACE(index_objs(ix).owner, '''', '''''') || ''',''' || REPLACE(index_objs(ix).index_name, '''', '''''') || ''')';
            END IF;
        END LOOP;
        IF in_list_index IS NULL OR in_list_index = '' THEN in_list_index := '(NULL,NULL)'; END IF;
        -- 用于 OBJECT SIZE 的 (plan ∪ table) 去重列表
        full_seg_objs := table_objs;
        FOR i IN 1..plan_objs.COUNT LOOP
            DECLARE
                found BOOLEAN := FALSE;
            BEGIN
                FOR j IN 1..full_seg_objs.COUNT LOOP
                    IF full_seg_objs(j).obj_owner = plan_objs(i).obj_owner AND full_seg_objs(j).obj_name = plan_objs(i).obj_name THEN
                        found := TRUE; EXIT;
                    END IF;
                END LOOP;
                IF NOT found THEN
                    full_seg_objs.EXTEND(1);
                    full_seg_objs(full_seg_objs.COUNT).obj_owner := plan_objs(i).obj_owner;
                    full_seg_objs(full_seg_objs.COUNT).obj_name  := plan_objs(i).obj_name;
                END IF;
            END;
        END LOOP;
        in_list_seg := '(NULL,NULL)';
        IF full_seg_objs IS NOT NULL AND full_seg_objs.COUNT > 0 THEN
            in_list_seg := '';
            FOR i IN 1..full_seg_objs.COUNT LOOP
                IF i > 1 THEN in_list_seg := in_list_seg || ','; END IF;
                in_list_seg := in_list_seg || '(''' || REPLACE(full_seg_objs(i).obj_owner, '''', '''''') || ''',''' || REPLACE(full_seg_objs(i).obj_name, '''', '''''') || ''')';
            END LOOP;
        END IF;

        put_line('****************************************************************************************');
        put_line('SQL_ID: ' || v_sql_id);
        put_line('****************************************************************************************');
        put_line('');
        put_line('LITERAL SQL');
        put_line('****************************************************************************************');

        -- LITERAL SQL：从 V$SQL 取 SQL_FULLTEXT（最多 32000 字符；put_line 内部分段输出，避免 YAS-04412）
        DECLARE
            lv_sql_text VARCHAR2(32000);
            lv_schema   VARCHAR2(128);
        BEGIN
            SELECT parsing_schema_name, SUBSTR(SQL_FULLTEXT, 1, 32000)
              INTO lv_schema, lv_sql_text
              FROM V$SQL
             WHERE SQL_ID = v_sql_id AND ROWNUM = 1;
            put_line( 'Schema: ' || lv_schema);
            put_line( lv_sql_text );
            put_line( '--------------------------------------------------------');
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                put_line( 'Schema: (not found)');
                put_line( '(SQL text not in V$SQL)');
                put_line( '--------------------------------------------------------');
        END;

        put_line( '');
        put_line( '****************************************************************************************');
        put_line( 'PLAN from v$ash_plan');
        put_line( '****************************************************************************************');

        -- PLAN：按 plan_hash_value 输出 v$sql_plan 表格（与 sql.sql 列、对齐一致）
        FOR pln IN (
            SELECT DISTINCT plan_hash_value
              FROM v$sql_plan
             WHERE sql_id = v_sql_id
             ORDER BY plan_hash_value
        ) LOOP
            put_line( '');
            put_line( '============================================================================');
            put_line( 'Plan Hash Value: ' || pln.plan_hash_value);
            put_line( '============================================================================');
            put_line( '');
            put_line( '|' || LPAD('ID', 4) || '|' || RPAD('OPERATION', 39) || '|' || RPAD('NAME', 29) || '|' || RPAD('ROWS', 11) || '|' || RPAD('COST', 9) || '|' || RPAD('TIME', 9) || '|');
            put_line( '|' || LPAD('-', 4, '-') || '|' || RPAD('-', 39, '-') || '|' || RPAD('-', 29, '-') || '|' || RPAD('-', 11, '-') || '|' || RPAD('-', 9, '-') || '|' || RPAD('-', 9, '-') || '|');
            FOR det IN (
                SELECT id, depth, position, operation, options, object_owner, object_name, object_type,
                       cost, cardinality, bytes, access_predicates, filter_predicates, partition_start, partition_stop
                  FROM v$sql_plan
                 WHERE sql_id = v_sql_id AND plan_hash_value = pln.plan_hash_value
                 ORDER BY id
            ) LOOP
                v_line := '|' || LPAD(NVL(TO_CHAR(det.id), ' '), 4) || '|' ||
                          RPAD(SUBSTR(LPAD(' ', det.depth*2) || det.operation || NVL(' '||det.options,'') || NVL(' ('||det.object_name||')',''), 1, 39), 39) || '|' ||
                          RPAD(SUBSTR(NVL(det.object_owner||'.'||det.object_name, ' '), 1, 29), 29) || '|' ||
                          RPAD(NVL(TO_CHAR(det.cardinality), ' '), 11) || '|' ||
                          RPAD(NVL(TO_CHAR(det.cost), ' '), 9) || '|' ||
                          RPAD(' ', 9) || '|';
                put_line( v_line);
                IF det.access_predicates IS NOT NULL THEN
                    put_line( '|    |  -> Access: ' || SUBSTR(det.access_predicates, 1, 26) || '|' || RPAD(' ', 29) || '|' || RPAD(' ', 11) || '|' || RPAD(' ', 9) || '|' || RPAD(' ', 9) || '|');
                END IF;
                IF det.filter_predicates IS NOT NULL THEN
                    put_line( '|    |  -> Filter: ' || SUBSTR(det.filter_predicates, 1, 26) || '|' || RPAD(' ', 29) || '|' || RPAD(' ', 11) || '|' || RPAD(' ', 9) || '|' || RPAD(' ', 9) || '|');
                END IF;
                IF det.partition_start IS NOT NULL OR det.partition_stop IS NOT NULL THEN
                    put_line( '|    |' || RPAD('  -> Partition: ' || NVL(TO_CHAR(det.partition_start), '?') || '..' || NVL(TO_CHAR(det.partition_stop), '?'), 39) || '|' || RPAD(' ', 29) || '|' || RPAD(' ', 11) || '|' || RPAD(' ', 9) || '|' || RPAD(' ', 9) || '|');
                END IF;
            END LOOP;
            put_line( '============================================================================');
        END LOOP;

        put_line( '');
        put_line( '+------------------------------------------------------------------------+');
        put_line( '| infromation  from v$sqlstats               |');
        put_line( '+------------------------------------------------------------------------+');
        put_line( '');
        -- 表头（与 sql.sql col 顺序一致：PLAN_HASH_VALUE, EXEC, CPU_PRE_EXEC, ...）
        put_line(RPAD('PLAN_HASH_VALUE',15) || RPAD('EXEC',10) || RPAD('CPU_PRE_EXEC',12) || RPAD('ELA_PRE_EXEC',12) || RPAD('DISK_PRE_EXEC',13) || RPAD('GET_PRE_EXEC',12) || RPAD('ROWS_PRE_EXEC',13) || RPAD('ROWS_PRE_FETCHES',15) || RPAD('APP_WAIT_PRE',12) || RPAD('CON_WAIT_PER',12) || RPAD('CLU_WAIT_PER',12) || RPAD('USER_IO_WAIT_PER',15) || RPAD('PLSQL_WAIT_PER',14) || RPAD('OUTLINE',20));

        -- v$sqlarea：查原始数值，用 fmt_num_kw/fmt_time_us 格式化输出
        FOR r IN (
            SELECT PLAN_HASH_VALUE||'' AS plan_hash_value, OUTLINE_CATEGORY AS outline,
                   EXECUTIONS AS executions,
                   CPU_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS cpu_per_exec,
                   ELAPSED_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS ela_per_exec,
                   DISK_READS/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS disk_per_exec,
                   BUFFER_GETS/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS get_per_exec,
                   ROWS_PROCESSED/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS rows_per_exec,
                   fetches/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS rows_per_fetches,
                   APPLICATION_WAIT_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS app_wait_per,
                   CONCURRENCY_WAIT_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS con_wait_per,
                   CLUSTER_WAIT_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS clu_wait_per,
                   USER_IO_WAIT_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS user_io_wait_per,
                   PLSQL_EXEC_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS plsql_wait_per
              FROM v$sqlarea
             WHERE sql_id = v_sql_id
        ) LOOP
            v_line := RPAD(SUBSTR(NVL(r.plan_hash_value,' '),1,15),15) || RPAD(SUBSTR(NVL(fmt_num_kw(r.executions),' '),1,10),10) || RPAD(SUBSTR(NVL(fmt_time_us(r.cpu_per_exec),' '),1,12),12) || RPAD(SUBSTR(NVL(fmt_time_us(r.ela_per_exec),' '),1,12),12) || RPAD(SUBSTR(NVL(fmt_num_kw(r.disk_per_exec),' '),1,13),13) || RPAD(SUBSTR(NVL(fmt_num_kw(r.get_per_exec),' '),1,12),12) || RPAD(SUBSTR(NVL(fmt_num_kw(r.rows_per_exec),' '),1,13),13) || RPAD(SUBSTR(NVL(fmt_num_kw(r.rows_per_fetches),' '),1,15),15) || RPAD(SUBSTR(NVL(fmt_time_us(r.app_wait_per),' '),1,12),12) || RPAD(SUBSTR(NVL(fmt_time_us(r.con_wait_per),' '),1,12),12) || RPAD(SUBSTR(NVL(fmt_time_us(r.clu_wait_per),' '),1,12),12) || RPAD(SUBSTR(NVL(fmt_time_us(r.user_io_wait_per),' '),1,15),15) || RPAD(SUBSTR(NVL(fmt_time_us(r.plsql_wait_per),' '),1,14),14) || RPAD(SUBSTR(NVL(r.outline,' '),1,20),20);
            put_line(v_line);
        END LOOP;

        put_line( '');
        put_line( '+------------------------------------------------------------------------+');
        put_line( '| information from v$sql                 |');
        put_line( '+------------------------------------------------------------------------+');
        put_line( '');
        put_line(RPAD('EXEC',10) || RPAD('PLAN_HASH_VALUE',15) || RPAD('C',3) || RPAD('USERNAME',15) || RPAD('CPU_PRE_EXEC',12) || RPAD('ELA_PRE_EXEC',12) || RPAD('DISK_PRE_EXEC',13) || RPAD('GET_PRE_EXEC',12) || RPAD('ROWS_PRE_EXEC',13) || RPAD('ROWS_PRE_FETCHES',15) || RPAD('APP_PRE_EXEC',12) || RPAD('CON_PRE_EXEC',12) || RPAD('CLU_WAIT_PER',12) || RPAD('USER_IO_WAIT_PER',15) || RPAD('PLSQL_WAIT_PER',14) || RPAD('F_L_TIME',15));

        FOR r2 IN (
            SELECT PLAN_HASH_VALUE||'' AS plan_hash_value, child_number||'' AS c, PARSING_SCHEMA_NAME AS username,
                   SUBSTR(FIRST_LOAD_TIME, 6, 10) || '.' || SUBSTR(LAST_LOAD_TIME, 6, 10) AS f_l_time,
                   EXECUTIONS AS executions,
                   CPU_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS cpu_per_exec,
                   ELAPSED_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS ela_per_exec,
                   DISK_READS/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS disk_per_exec,
                   BUFFER_GETS/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS get_per_exec,
                   ROWS_PROCESSED/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS rows_per_exec,
                   ROWS_PROCESSED/DECODE(FETCHES,0,1,FETCHES) AS rows_per_fetches,
                   APPLICATION_WAIT_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS app_pre_exec,
                   CONCURRENCY_WAIT_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS con_pre_exec,
                   CLUSTER_WAIT_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS clu_wait_per,
                   USER_IO_WAIT_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS user_io_wait_per,
                   PLSQL_EXEC_TIME/DECODE(EXECUTIONS,0,1,EXECUTIONS) AS plsql_wait_per
              FROM v$sql
             WHERE sql_id = v_sql_id
             ORDER BY plan_hash_value
        ) LOOP
            v_line := RPAD(SUBSTR(NVL(fmt_num_kw(r2.executions),' '),1,10),10) || RPAD(SUBSTR(NVL(r2.plan_hash_value,' '),1,15),15) || RPAD(SUBSTR(NVL(r2.c,' '),1,3),3) || RPAD(SUBSTR(NVL(r2.username,' '),1,15),15) || RPAD(SUBSTR(NVL(fmt_time_us(r2.cpu_per_exec),' '),1,12),12) || RPAD(SUBSTR(NVL(fmt_time_us(r2.ela_per_exec),' '),1,12),12) || RPAD(SUBSTR(NVL(fmt_num_kw(r2.disk_per_exec),' '),1,13),13) || RPAD(SUBSTR(NVL(fmt_num_kw(r2.get_per_exec),' '),1,12),12) || RPAD(SUBSTR(NVL(fmt_num_kw(r2.rows_per_exec),' '),1,13),13) || RPAD(SUBSTR(NVL(fmt_num_kw(r2.rows_per_fetches),' '),1,15),15) || RPAD(SUBSTR(NVL(fmt_time_us(r2.app_pre_exec),' '),1,12),12) || RPAD(SUBSTR(NVL(fmt_time_us(r2.con_pre_exec),' '),1,12),12) || RPAD(SUBSTR(NVL(fmt_time_us(r2.clu_wait_per),' '),1,12),12) || RPAD(SUBSTR(NVL(fmt_time_us(r2.user_io_wait_per),' '),1,15),15) || RPAD(SUBSTR(NVL(fmt_time_us(r2.plsql_wait_per),' '),1,14),14) || RPAD(SUBSTR(NVL(r2.f_l_time,' '),1,15),15);
            put_line(v_line);
        END LOOP;

        put_line( '');
        put_line( '+------------------------------------------------------------------------+');
        put_line( '| information from awr   sysdate-' || v_days || '                                       |');
        put_line( '+------------------------------------------------------------------------+');
        put_line( '');
        put_line(RPAD('END_TIME',8) || RPAD('I',2) || RPAD('USERNAME',15) || RPAD('PLAN_HASH_VALUE',15) || RPAD('EXEC',10) || RPAD('CPU_PRE_EXEC',12) || RPAD('ELA_PRE_EXEC',12) || RPAD('DISK_PRE_EXEC',13) || RPAD('GET_PRE_EXEC',12) || RPAD('ROWS_PRE_EXEC',13) || RPAD('ROWS_PRE_FETCHES',15) || RPAD('WRITE_PRE_EXEC',14) || RPAD('IOWAIT_PRE_EXEC',15) || RPAD('SORTS_PRE_EXEC',15) || RPAD('APP_PRE_EXEC',12) || RPAD('CON_PRE_EXEC',12) || RPAD('CLU_WAIT_PER',12) || RPAD('PLSQL_WAIT_PER',14));

        FOR awr IN (
            SELECT TO_CHAR(b.END_INTERVAL_TIME, 'dd hh24') AS end_time,
                   TRIM(TO_CHAR(a.instance_number)) AS i,
                   a.parsing_schema_name AS username,
                   a.plan_hash_value||'' AS plan_hash_value,
                   executions_delta AS executions,
                   cpu_time_delta/DECODE(executions_delta,0,1,executions_delta) AS cpu_per_exec,
                   elapsed_time_delta/DECODE(executions_delta,0,1,executions_delta) AS ela_per_exec,
                   disk_reads_delta/DECODE(executions_delta,0,1,executions_delta) AS disk_per_exec,
                   BUFFER_GETS_DELTA/DECODE(executions_delta,0,1,executions_delta) AS get_per_exec,
                   rows_processed_delta/DECODE(executions_delta,0,1,executions_delta) AS rows_per_exec,
                   fetches_delta/DECODE(executions_delta,0,1,executions_delta) AS rows_per_fetches,
                   direct_writes_delta/DECODE(executions_delta,0,1,executions_delta) AS write_per_exec,
                   IOWAIT_DELTA/DECODE(executions_delta,0,1,executions_delta) AS iowait_per_exec,
                   sorts_delta/DECODE(executions_delta,0,1,executions_delta) AS sorts_per_exec,
                   apwait_delta/DECODE(executions_delta,0,1,executions_delta) AS app_pre_exec,
                   ccwait_delta/DECODE(executions_delta,0,1,executions_delta) AS con_pre_exec,
                   clwait_delta/DECODE(executions_delta,0,1,executions_delta) AS clu_wait_per,
                   plsexec_time_delta/DECODE(executions_delta,0,1,executions_delta) AS plsql_wait_per
              FROM SYS.WRH$_SQLSTAT a, SYS.WRM$_SNAPSHOT b
             WHERE a.sql_id = v_sql_id
               AND a.snap_id = b.snap_id
               AND b.END_INTERVAL_TIME > SYSDATE - v_days
               AND a.instance_number = b.instance_number
             ORDER BY 1
        ) LOOP
            v_line := RPAD(SUBSTR(NVL(awr.end_time,' '),1,8),8) || RPAD(SUBSTR(NVL(awr.i,' '),1,2),2) || RPAD(SUBSTR(NVL(awr.username,' '),1,15),15) || RPAD(SUBSTR(NVL(awr.plan_hash_value,' '),1,15),15) || RPAD(SUBSTR(NVL(fmt_num_kw(awr.executions),' '),1,10),10) || RPAD(SUBSTR(NVL(fmt_time_us(awr.cpu_per_exec),' '),1,12),12) || RPAD(SUBSTR(NVL(fmt_time_us(awr.ela_per_exec),' '),1,12),12) || RPAD(SUBSTR(NVL(fmt_num_kw(awr.disk_per_exec),' '),1,13),13) || RPAD(SUBSTR(NVL(fmt_num_kw(awr.get_per_exec),' '),1,12),12) || RPAD(SUBSTR(NVL(fmt_num_kw(awr.rows_per_exec),' '),1,13),13) || RPAD(SUBSTR(NVL(fmt_num_kw(awr.rows_per_fetches),' '),1,15),15) || RPAD(SUBSTR(NVL(fmt_num_kw(awr.write_per_exec),' '),1,14),14) || RPAD(SUBSTR(NVL(fmt_time_us(awr.iowait_per_exec),' '),1,15),15) || RPAD(SUBSTR(NVL(fmt_num_kw(awr.sorts_per_exec),' '),1,15),15) || RPAD(SUBSTR(NVL(fmt_time_us(awr.app_pre_exec),' '),1,12),12) || RPAD(SUBSTR(NVL(fmt_time_us(awr.con_pre_exec),' '),1,12),12) || RPAD(SUBSTR(NVL(fmt_time_us(awr.clu_wait_per),' '),1,12),12) || RPAD(SUBSTR(NVL(fmt_time_us(awr.plsql_wait_per),' '),1,14),14);
            put_line(v_line);
        END LOOP;

        -- OBJECT SIZE：列名、对齐与 sql.sql 一致；segment_name 对表对象前加 ***
        put_line( '');
        put_line( '****************************************************************************************');
        put_line( 'OBJECT SIZE');
        put_line( '****************************************************************************************');
        put_line(RPAD('OWNER',15) || RPAD('SEGMENT_NAME',25) || RPAD('SEGMENT_TYPE',20) || RPAD('SEGMENT_SIZE',15));

        DECLARE
            TYPE seg_rec IS RECORD (owner VARCHAR2(128), segment_name VARCHAR2(128), segment_type VARCHAR2(20), segment_size VARCHAR2(64));
            TYPE seg_tab IS TABLE OF seg_rec;
            seg_coll seg_tab;
            seg_name_disp VARCHAR2(256);
            is_tbl BOOLEAN;
        BEGIN
            EXECUTE IMMEDIATE
                'SELECT b.owner, b.segment_name, b.segment_type, TO_CHAR(TRUNC(b.bytes/1024/1024))||''M'' AS segment_size FROM (
                    SELECT owner, segment_name, segment_type, SUM(bytes) bytes FROM dba_segments
                    WHERE (owner, segment_name) IN (' || in_list_seg || ') GROUP BY owner, segment_type, segment_name
                ) b ORDER BY b.owner, b.segment_name'
                BULK COLLECT INTO seg_coll;
            FOR i IN 1..NVL(seg_coll.COUNT, 0) LOOP
                is_tbl := FALSE;
                FOR j IN 1..table_objs.COUNT LOOP
                    IF table_objs(j).obj_owner = seg_coll(i).owner AND table_objs(j).obj_name = seg_coll(i).segment_name THEN
                        is_tbl := TRUE; EXIT;
                    END IF;
                END LOOP;
                seg_name_disp := CASE WHEN is_tbl THEN '***' || seg_coll(i).segment_name ELSE seg_coll(i).segment_name END;
                v_line := RPAD(SUBSTR(NVL(seg_coll(i).owner,' '),1,15),15) || RPAD(SUBSTR(NVL(seg_name_disp,' '),1,25),25) || RPAD(SUBSTR(NVL(seg_coll(i).segment_type,' '),1,20),20) || RPAD(SUBSTR(NVL(seg_coll(i).segment_size,' '),1,15),15);
                put_line(v_line);
            END LOOP;
        END;

        put_line( '');
        put_line( '****************************************************************************************');
        put_line( 'TABLES');
        put_line( '****************************************************************************************');
        put_line(RPAD('OWNER',15) || RPAD('TABLE_NAME',25) || RPAD('L_T',5) || RPAD('DEGREE',7) || RPAD('PART',5) || RPAD('NUM_ROWS',10) || RPAD('BLOCKS',10) || RPAD('EMPTY_BLOCKS',13) || RPAD('AVG_SPACE',11) || RPAD('AVG_ROW_LEN',12) || RPAD('BLOCK_SIZE',11) || RPAD('AVG_SIZE',10) || RPAD('STALE_STATS',12) || RPAD('LAST_ANALYZED',25));

        DECLARE
            TYPE tbl_rec IS RECORD (owner VARCHAR2(128), table_name VARCHAR2(128), l_t VARCHAR2(20), degree VARCHAR2(40), part VARCHAR2(3), num_rows VARCHAR2(40), blocks VARCHAR2(40), empty_blocks VARCHAR2(40), avg_space VARCHAR2(40), avg_row_len VARCHAR2(40), block_size VARCHAR2(40), avg_size VARCHAR2(40), stale_stats VARCHAR2(20), last_analyzed DATE);
            TYPE tbl_tab IS TABLE OF tbl_rec;
            tbl_coll tbl_tab;
        BEGIN
            EXECUTE IMMEDIATE
                'SELECT a.owner, a.TABLE_NAME, a.LOGGING||''.''||a.TEMPORARY AS l_t, LTRIM(a.DEGREE) AS degree, a.PARTITIONED AS part, a.NUM_ROWS||'''' AS num_rows, a.BLOCKS||'''' AS blocks, a.EMPTY_BLOCKS||'''' AS empty_blocks, b.AVG_SPACE||'''' AS avg_space, b.AVG_ROW_LEN||'''' AS avg_row_len, TO_CHAR(TRUNC((b.blocks*tp.block_size)/1024/1024)) AS block_size, TO_CHAR(TRUNC((b.AVG_ROW_LEN*b.NUM_ROWS)/1024/1024)) AS avg_size, b.STALE_STATS||'''' AS stale_stats, a.LAST_ANALYZED FROM DBA_TABLES a, dba_tab_statistics b, dba_tablespaces tp WHERE (a.OWNER, a.TABLE_NAME) IN (' || in_list_table || ') AND a.owner = b.owner(+) AND a.table_name = b.table_name(+) AND a.tablespace_name = tp.tablespace_name ORDER BY a.owner, a.table_name'
                BULK COLLECT INTO tbl_coll;
            FOR i IN 1..NVL(tbl_coll.COUNT, 0) LOOP
                v_line := RPAD(SUBSTR(NVL(tbl_coll(i).owner,' '),1,15),15) || RPAD(SUBSTR(NVL(tbl_coll(i).table_name,' '),1,25),25) || RPAD(SUBSTR(NVL(tbl_coll(i).l_t,' '),1,5),5) || RPAD(SUBSTR(NVL(tbl_coll(i).degree,' '),1,7),7) || RPAD(SUBSTR(NVL(tbl_coll(i).part,' '),1,5),5) || RPAD(SUBSTR(NVL(tbl_coll(i).num_rows,' '),1,10),10) || RPAD(SUBSTR(NVL(tbl_coll(i).blocks,' '),1,10),10) || RPAD(SUBSTR(NVL(tbl_coll(i).empty_blocks,' '),1,13),13) || RPAD(SUBSTR(NVL(tbl_coll(i).avg_space,' '),1,11),11) || RPAD(SUBSTR(NVL(tbl_coll(i).avg_row_len,' '),1,12),12) || RPAD(SUBSTR(NVL(tbl_coll(i).block_size,' '),1,11),11) || RPAD(SUBSTR(NVL(tbl_coll(i).avg_size,' '),1,10),10) || RPAD(SUBSTR(NVL(tbl_coll(i).stale_stats,' '),1,12),12) || RPAD(SUBSTR(NVL(TO_CHAR(tbl_coll(i).last_analyzed,'yyyy-mm-dd hh24:mi:ss'),' '),1,25),25);
                put_line(v_line);
            END LOOP;
        END;

        put_line( '');
        put_line( '****************************************************************************************');
        put_line( 'TABLE COLUMNS');
        put_line( '****************************************************************************************');
        put_line(RPAD('OWNER',15) || RPAD('TABLE_NAME',25) || RPAD('COLUMN_NAME',15) || RPAD('D_TYPE',20) || RPAD('NUM_DISTINCT',13) || RPAD('N',2) || RPAD('NUM_NULLS',10) || RPAD('DENSITY',10) || RPAD('NUM_BUCKETS',12) || RPAD('AVG_COL_LEN',12) || RPAD('SAMPLE_SIZE',12) || RPAD('HISTOGRAM',10) || RPAD('LAST_ANALYZED',13));

        DECLARE
            TYPE col_rec IS RECORD (owner VARCHAR2(128), table_name VARCHAR2(128), column_name VARCHAR2(128), d_type VARCHAR2(64), num_distinct VARCHAR2(40), n VARCHAR2(10), num_nulls VARCHAR2(40), density VARCHAR2(40), num_buckets VARCHAR2(40), avg_col_len VARCHAR2(40), sample_size VARCHAR2(40), histogram VARCHAR2(10), last_analyzed DATE);
            TYPE col_tab IS TABLE OF col_rec;
            col_coll col_tab;
        BEGIN
            EXECUTE IMMEDIATE
                'SELECT a.OWNER, a.TABLE_NAME, a.COLUMN_NAME, a.data_type||''(''||a.data_length||'')'' AS d_type, b.NUM_DISTINCT||'''' AS num_distinct, a.NULLABLE||'''' AS n, b.NUM_NULLS||'''' AS num_nulls, NVL(TO_CHAR(b.DENSITY,''FM999999999990.999999999999''),'' '') AS density, b.NUM_BUCKETS||'''' AS num_buckets, b.AVG_COL_LEN||'''' AS avg_col_len, b.sample_size||'''' AS sample_size, SUBSTR(b.HISTOGRAM,1,5) AS histogram, b.LAST_ANALYZED FROM DBA_TAB_COLS a, DBA_TAB_COL_STATISTICS b WHERE (a.OWNER, a.TABLE_NAME) IN (' || in_list_table || ') AND a.owner = b.owner(+) AND a.table_name = b.table_name(+) AND a.column_name = b.column_name(+) ORDER BY a.owner, a.table_name, a.COLUMN_ID'
                BULK COLLECT INTO col_coll;
            FOR i IN 1..NVL(col_coll.COUNT, 0) LOOP
                v_line := RPAD(SUBSTR(NVL(col_coll(i).owner,' '),1,15),15) || RPAD(SUBSTR(NVL(col_coll(i).table_name,' '),1,25),25) || RPAD(SUBSTR(NVL(col_coll(i).column_name,' '),1,15),15) || RPAD(SUBSTR(NVL(col_coll(i).d_type,' '),1,20),20) || RPAD(SUBSTR(NVL(col_coll(i).num_distinct,' '),1,13),13) || RPAD(SUBSTR(NVL(col_coll(i).n,' '),1,2),2) || RPAD(SUBSTR(NVL(col_coll(i).num_nulls,' '),1,10),10) || RPAD(SUBSTR(NVL(col_coll(i).density,' '),1,10),10) || RPAD(SUBSTR(NVL(col_coll(i).num_buckets,' '),1,12),12) || RPAD(SUBSTR(NVL(col_coll(i).avg_col_len,' '),1,12),12) || RPAD(SUBSTR(NVL(col_coll(i).sample_size,' '),1,12),12) || RPAD(SUBSTR(NVL(col_coll(i).histogram,' '),1,10),10) || RPAD(SUBSTR(NVL(TO_CHAR(col_coll(i).last_analyzed,'yyyy-mm-dd'),' '),1,13),13);
                put_line(v_line);
            END LOOP;
        END;

        put_line( '');
        put_line( '****************************************************************************************');
        put_line( 'INDEX STATUS');
        put_line( '****************************************************************************************');
        put_line(RPAD('OWNER',15) || RPAD('INDEX_NAME',20) || RPAD('PARTITION_NAME',20) || RPAD('SUBPARTITION_NAME',20) || RPAD('STATUS',10));

        FOR ix IN 1..NVL(index_objs.COUNT, 0) LOOP
            IF index_objs(ix).partitioned = 'NO' THEN
                v_line := RPAD(SUBSTR(NVL(index_objs(ix).owner,' '),1,15),15) || RPAD(SUBSTR(NVL(index_objs(ix).index_name,' '),1,20),20) || RPAD(' ',20) || RPAD(' ',20) || RPAD(SUBSTR(NVL(index_objs(ix).status,' '),1,10),10);
                put_line(v_line);
            END IF;
        END LOOP;
        DECLARE
            TYPE idx_rec IS RECORD (owner VARCHAR2(128), index_name VARCHAR2(128), partition_name VARCHAR2(128), subpartition_name VARCHAR2(128), status VARCHAR2(20));
            TYPE idx_tab IS TABLE OF idx_rec;
            idx_coll idx_tab;
        BEGIN
            EXECUTE IMMEDIATE
                'SELECT p.INDEX_OWNER, p.INDEX_NAME, PARTITION_NAME, '' '' AS subpartition_name, p.status FROM dba_ind_partitions p WHERE (p.INDEX_OWNER, p.INDEX_NAME) IN (' || in_list_index || ') AND p.status NOT IN (''USABLE'') ORDER BY 1,2,3'
                BULK COLLECT INTO idx_coll;
            FOR i IN 1..NVL(idx_coll.COUNT, 0) LOOP
                v_line := RPAD(SUBSTR(NVL(idx_coll(i).owner,' '),1,15),15) || RPAD(SUBSTR(NVL(idx_coll(i).index_name,' '),1,20),20) || RPAD(SUBSTR(NVL(idx_coll(i).partition_name,' '),1,20),20) || RPAD(SUBSTR(NVL(idx_coll(i).subpartition_name,' '),1,20),20) || RPAD(SUBSTR(NVL(idx_coll(i).status,' '),1,10),10);
                put_line(v_line);
            END LOOP;
            EXECUTE IMMEDIATE
                'SELECT p.INDEX_OWNER, p.INDEX_NAME, PARTITION_NAME, SUBPARTITION_NAME, p.status FROM dba_ind_subpartitions p WHERE (p.INDEX_OWNER, p.INDEX_NAME) IN (' || in_list_index || ') AND p.status NOT IN (''USABLE'') ORDER BY 1,2,3,4'
                BULK COLLECT INTO idx_coll;
            FOR i IN 1..NVL(idx_coll.COUNT, 0) LOOP
                v_line := RPAD(SUBSTR(NVL(idx_coll(i).owner,' '),1,15),15) || RPAD(SUBSTR(NVL(idx_coll(i).index_name,' '),1,20),20) || RPAD(SUBSTR(NVL(idx_coll(i).partition_name,' '),1,20),20) || RPAD(SUBSTR(NVL(idx_coll(i).subpartition_name,' '),1,20),20) || RPAD(SUBSTR(NVL(idx_coll(i).status,' '),1,10),10);
                put_line(v_line);
            END LOOP;
        END;

        put_line( '');
        put_line( '****************************************************************************************');
        put_line( 'INDEX INFO');
        put_line( '****************************************************************************************');
        put_line(RPAD('TABLE_OWNER',15) || RPAD('TABLE_NAME',25) || RPAD('INDEX_NAME',20) || RPAD('UCPTV',6) || RPAD('COLUMN_NAME',30) || RPAD('COLUMN_POSITION',16) || RPAD('DESCEND',10));

        DECLARE
            TYPE idx2_rec IS RECORD (table_owner VARCHAR2(128), table_name VARCHAR2(128), index_name VARCHAR2(128), ucptv VARCHAR2(20), column_name VARCHAR2(128), column_position NUMBER, descend VARCHAR2(10));
            TYPE idx2_tab IS TABLE OF idx2_rec;
            idx2_coll idx2_tab;
        BEGIN
            EXECUTE IMMEDIATE
                'SELECT A.TABLE_OWNER, A.TABLE_NAME, A.INDEX_NAME, DECODE(A.UNIQUENESS,''UNIQUE'',''U'',''NONUNIQUE'',''N'',''O'')||DECODE(A.COMPRESSION,''ENABLED'',''E'',''DISABLED'',''N'',''O'')||DECODE(A.PARTITIONED,''YES'',''Y'',''NO'',''N'',''O'')||DECODE(A.TEMPORARY,''Y'',''Y'',''N'',''N'',''O'')||DECODE(A.VISIBILITY,''VISIBLE'',''V'',''INVISIBLE'',''I'',''O'') AS ucptv, B.COLUMN_NAME, B.COLUMN_POSITION, B.DESCEND FROM DBA_INDEXES A, DBA_IND_COLUMNS B WHERE (A.OWNER, A.table_name) IN (' || in_list_table || ') AND A.OWNER = B.INDEX_OWNER AND A.INDEX_NAME = B.INDEX_NAME ORDER BY A.table_owner, A.table_name, A.index_name, B.COLUMN_POSITION'
                BULK COLLECT INTO idx2_coll;
            FOR i IN 1..NVL(idx2_coll.COUNT, 0) LOOP
                v_line := RPAD(SUBSTR(NVL(idx2_coll(i).table_owner,' '),1,15),15) || RPAD(SUBSTR(NVL(idx2_coll(i).table_name,' '),1,25),25) || RPAD(SUBSTR(NVL(idx2_coll(i).index_name,' '),1,20),20) || RPAD(SUBSTR(NVL(idx2_coll(i).ucptv,' '),1,6),6) || RPAD(SUBSTR(NVL(idx2_coll(i).column_name,' '),1,30),30) || RPAD(SUBSTR(NVL(TO_CHAR(idx2_coll(i).column_position),' '),1,16),16) || RPAD(SUBSTR(NVL(idx2_coll(i).descend,' '),1,10),10);
                put_line(v_line);
            END LOOP;
        END;

        -- PARTITION INDEX（与 sql.sql 一致）
        put_line( '');
        put_line( '****************************************************************************************');
        put_line( 'PARTITION INDEX');
        put_line( '****************************************************************************************');
        put_line(RPAD('OWNER',15) || RPAD('INDEX_NAME',20) || RPAD('PART_TYPE',15) || RPAD('SUBPART_TYPE',15) || RPAD('PART_COUNT',11) || RPAD('KEY_COUNT',10) || RPAD('SUBKEY_COUT',12) || RPAD('LOCALITY',10) || RPAD('COLUMN_NAME',30) || RPAD('COLUMN_POSITION',16));

        DECLARE
            TYPE part_idx_rec IS RECORD (owner VARCHAR2(128), index_name VARCHAR2(128), part_type VARCHAR2(20), subpart_type VARCHAR2(20), part_count VARCHAR2(20), key_count VARCHAR2(20), subkey_cout VARCHAR2(20), locality VARCHAR2(20), column_name VARCHAR2(128), column_position NUMBER);
            TYPE part_idx_tab IS TABLE OF part_idx_rec;
            part_idx_coll part_idx_tab;
        BEGIN
            EXECUTE IMMEDIATE
                'SELECT a.owner, a.name AS index_name, b.partitioning_type AS part_type, b.subpartitioning_type AS subpart_type, b.partition_count||'''' AS part_count, b.PARTITIONING_KEY_COUNT||'''' AS key_count, b.SUBPARTITIONING_KEY_COUNT||'''' AS subkey_cout, b.LOCALITY||'''' AS locality, a.COLUMN_NAME, a.COLUMN_POSITION FROM DBA_PART_KEY_COLUMNS a, dba_part_indexes b WHERE a.name = b.index_name AND (b.owner, b.index_name) IN (SELECT owner, index_name FROM dba_indexes WHERE (table_owner, table_name) IN (' || in_list_table || ')) AND a.owner = b.owner ORDER BY a.owner, a.name, a.column_position'
                BULK COLLECT INTO part_idx_coll;
            FOR i IN 1..NVL(part_idx_coll.COUNT, 0) LOOP
                v_line := RPAD(SUBSTR(NVL(part_idx_coll(i).owner,' '),1,15),15) || RPAD(SUBSTR(NVL(part_idx_coll(i).index_name,' '),1,20),20) || RPAD(SUBSTR(NVL(part_idx_coll(i).part_type,' '),1,15),15) || RPAD(SUBSTR(NVL(part_idx_coll(i).subpart_type,' '),1,15),15) || RPAD(SUBSTR(NVL(part_idx_coll(i).part_count,' '),1,11),11) || RPAD(SUBSTR(NVL(part_idx_coll(i).key_count,' '),1,10),10) || RPAD(SUBSTR(NVL(part_idx_coll(i).subkey_cout,' '),1,12),12) || RPAD(SUBSTR(NVL(part_idx_coll(i).locality,' '),1,10),10) || RPAD(SUBSTR(NVL(part_idx_coll(i).column_name,' '),1,30),30) || RPAD(SUBSTR(NVL(TO_CHAR(part_idx_coll(i).column_position),' '),1,16),16);
                put_line(v_line);
            END LOOP;
        END;

        -- PARTITION TABLE（与 sql.sql 一致）
        put_line( '');
        put_line( '****************************************************************************************');
        put_line( 'PARTITION TABLE');
        put_line( '****************************************************************************************');
        put_line(RPAD('OWNER',15) || RPAD('TABLE_NAME',25) || RPAD('PART_TYPE',15) || RPAD('SUBPART_TYPE',15) || RPAD('PART_COUNT',11) || RPAD('KEY_COUNT',10) || RPAD('SUBKEY_COUT',12) || RPAD('COLUMN_NAME',30) || RPAD('COLUMN_POSITION',16));

        DECLARE
            TYPE part_tbl_rec IS RECORD (owner VARCHAR2(128), table_name VARCHAR2(128), part_type VARCHAR2(20), subpart_type VARCHAR2(20), part_count VARCHAR2(20), key_count VARCHAR2(20), subkey_cout VARCHAR2(20), column_name VARCHAR2(128), column_position NUMBER);
            TYPE part_tbl_tab IS TABLE OF part_tbl_rec;
            part_tbl_coll part_tbl_tab;
        BEGIN
            EXECUTE IMMEDIATE
                'SELECT a.owner, a.name AS table_name, b.partitioning_type AS part_type, b.subpartitioning_type AS subpart_type, b.partition_count||'''' AS part_count, b.PARTITIONING_KEY_COUNT||'''' AS key_count, b.SUBPARTITIONING_KEY_COUNT||'''' AS subkey_cout, a.COLUMN_NAME, a.COLUMN_POSITION FROM DBA_PART_KEY_COLUMNS a, dba_part_tables b WHERE a.name = b.table_name AND (a.owner, a.name) IN (' || in_list_table || ') AND a.owner = b.owner ORDER BY a.NAME, a.COLUMN_POSITION'
                BULK COLLECT INTO part_tbl_coll;
            FOR i IN 1..NVL(part_tbl_coll.COUNT, 0) LOOP
                v_line := RPAD(SUBSTR(NVL(part_tbl_coll(i).owner,' '),1,15),15) || RPAD(SUBSTR(NVL(part_tbl_coll(i).table_name,' '),1,25),25) || RPAD(SUBSTR(NVL(part_tbl_coll(i).part_type,' '),1,15),15) || RPAD(SUBSTR(NVL(part_tbl_coll(i).subpart_type,' '),1,15),15) || RPAD(SUBSTR(NVL(part_tbl_coll(i).part_count,' '),1,11),11) || RPAD(SUBSTR(NVL(part_tbl_coll(i).key_count,' '),1,10),10) || RPAD(SUBSTR(NVL(part_tbl_coll(i).subkey_cout,' '),1,12),12) || RPAD(SUBSTR(NVL(part_tbl_coll(i).column_name,' '),1,30),30) || RPAD(SUBSTR(NVL(TO_CHAR(part_tbl_coll(i).column_position),' '),1,16),16);
                put_line(v_line);
            END LOOP;
        END;

        -- display every partition info（与 sql.sql 一致：DBA_TAB_PARTITIONS）
        put_line( '');
        put_line( '****************************************************************************************');
        put_line( 'display every partition  info');
        put_line( '****************************************************************************************');
        put_line(RPAD('TABLE_NAME',25) || RPAD('PARTITION_NAME',20) || RPAD('HIGH_VALUE',25) || RPAD('HIGH_VALUE_LENGTH',19) || RPAD('TABLESPACE_NAME',16) || RPAD('NUM_ROWS',10) || RPAD('BLOCKS',10) || RPAD('T_SIZE',10) || RPAD('EMPTY_BLOCKS',13) || RPAD('LAST_ANALYZED',14) || RPAD('AVG_SPACE',11) || RPAD('SUBPART_COUNT',13));

        DECLARE
            TYPE tab_part_rec IS RECORD (table_name VARCHAR2(128), partition_name VARCHAR2(128), high_value VARCHAR2(4000), high_value_length VARCHAR2(20), tablespace_name VARCHAR2(128), num_rows VARCHAR2(20), blocks VARCHAR2(20), t_size VARCHAR2(20), empty_blocks VARCHAR2(20), last_analyzed VARCHAR2(20), avg_space VARCHAR2(20), subpart_count VARCHAR2(20));
            TYPE tab_part_tab IS TABLE OF tab_part_rec;
            tab_part_coll tab_part_tab;
        BEGIN
            EXECUTE IMMEDIATE
                'SELECT table_name, PARTITION_NAME, SUBSTR(HIGH_VALUE,1,25) AS high_value, TO_CHAR(HIGH_VALUE_LENGTH) AS high_value_length, TABLESPACE_NAME, NUM_ROWS||'''' AS num_rows, BLOCKS||'''' AS blocks, TO_CHAR(ROUND(blocks*8/1024,2))||''KB'' AS t_size, EMPTY_BLOCKS||'''' AS empty_blocks, TO_CHAR(LAST_ANALYZED,''yyyy-mm-dd'') AS last_analyzed, AVG_SPACE||'''' AS avg_space, SUBPARTITION_COUNT||'''' AS subpart_count FROM DBA_TAB_PARTITIONS WHERE (table_owner, table_name) IN (' || in_list_table || ') ORDER BY table_name, PARTITION_POSITION'
                BULK COLLECT INTO tab_part_coll;
            FOR i IN 1..NVL(tab_part_coll.COUNT, 0) LOOP
                v_line := RPAD(SUBSTR(NVL(tab_part_coll(i).table_name,' '),1,25),25) || RPAD(SUBSTR(NVL(tab_part_coll(i).partition_name,' '),1,20),20) || RPAD(SUBSTR(NVL(tab_part_coll(i).high_value,' '),1,25),25) || RPAD(SUBSTR(NVL(tab_part_coll(i).high_value_length,' '),1,19),19) || RPAD(SUBSTR(NVL(tab_part_coll(i).tablespace_name,' '),1,16),16) || RPAD(SUBSTR(NVL(tab_part_coll(i).num_rows,' '),1,10),10) || RPAD(SUBSTR(NVL(tab_part_coll(i).blocks,' '),1,10),10) || RPAD(SUBSTR(NVL(tab_part_coll(i).t_size,' '),1,10),10) || RPAD(SUBSTR(NVL(tab_part_coll(i).empty_blocks,' '),1,13),13) || RPAD(SUBSTR(NVL(tab_part_coll(i).last_analyzed,' '),1,14),14) || RPAD(SUBSTR(NVL(tab_part_coll(i).avg_space,' '),1,11),11) || RPAD(SUBSTR(NVL(tab_part_coll(i).subpart_count,' '),1,13),13);
                put_line(v_line);
            END LOOP;
        END;

        DBMS_OUTPUT.PUT_LINE('--- Output done for SQL_ID: ' || v_sql_id || ' ---');
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('Done. Total SQL_IDs written: ' || v_count);
END;
/

-- ============================================================================
-- 验证方法（改写的 SQL 验证）：
-- 1) 先单独执行 awr_sql_by_cpu_by_day.sql：设置 days_back=1, days_show=1，得到当日 TOP 10 的 SQL_ID 列表及列。
-- 2) 执行本脚本后，检查生成文件数量是否与 TOP N 一致，且 SQL_ID 与 AWR 列表一致。
-- 3) 任选一个 SQL_ID，用 sql.sql 手动执行（DEFINE sqlid=该id，SPOOL 到文件），与本脚本生成的 top_sql_<sql_id>.txt 对比：
--    - LITERAL SQL / PLAN / v$sqlarea / v$sql / AWR 各段列名与顺序与 sql.sql 输出一致；
--    - OBJECT SIZE / TABLES 等通过 PL/SQL 集合与动态 SQL IN 列表复用，结果集与原先 WITH 子查询一致。
-- 4) 确认每个 SQL_ID 只对应一个文件，且 V$SQL_PLAN 在每个 SQL_ID 下只被查询一次（通过集合复用，不建表）。
-- ============================================================================
