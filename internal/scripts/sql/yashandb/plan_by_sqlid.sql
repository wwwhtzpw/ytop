-- File Name: plan_by_sqlid.sql
-- Purpose: YashanDB Show execution plan by sql_id from v$sql_plan
-- Created: 20260516  by  huangtingzhong
-- Updated: 20260806  by  huangtingzhong
-- Notes:
--   Pure SQL output (no DBMS_OUTPUT / anonymous PL/SQL).
--   Works on READ_ONLY standby where DBMS_OUTPUT.PUT_LINE raises YAS-05398.
--   Column widths auto-size per plan_hash_value (Operation/Name capped at 120).
--   Truncate Access/Filter/Projection/etc. early to avoid YAS-04412 on long predicates.
--   One row per (plan_hash_value, id); no duplicate plan lines.
--   Pid = parent_id; Ord = id order (no PL/SQL tree walk).
--   Table: Rows / Bytes / Cost / Time.
--   Extra lines (when present): Access / Filter / Partition / Other / Temp /
--     SearchCols / CpuIo / Projection. OBJECT_ALIAS appended in Name.

prompt ****************************************************************************************
prompt PLAN from v$sql_plan  (sql_id = &&sqlid)
prompt ****************************************************************************************

-- Do not set "col plan_line for aN": yasql pads every row to N chars,
-- leaving a large blank area after the trailing "|".

-- One row per (plan_hash_value, id): collapse multi-child / multi-address
-- copies in v$sql_plan so each PHV prints a single plan tree.
WITH ranked AS (
  SELECT p.plan_hash_value AS phv,
         p.id,
         p.parent_id,
         p.depth,
         p.operation,
         p.options,
         p.object_owner,
         p.object_name,
         p.object_type,
         p.object_alias,
         p.cost,
         p.cardinality,
         p.bytes,
         p.time AS plan_time,
         p.cpu_cost,
         p.io_cost,
         p.search_columns,
         p.access_predicates,
         p.filter_predicates,
         p.projection,
         p.partition_info,
         p.partition_start,
         p.partition_stop,
         p.other_tag,
         p.temp_space,
         -- Cap long text early: yasql/engine VARCHAR buffer (YAS-04412) if predicates huge
         SUBSTR(
           LPAD(' ', NVL(p.depth, 0) * 2) || p.operation || NVL(' ' || p.options, ''),
           1, 120
         ) AS op_txt,
         SUBSTR(
           CASE
             WHEN p.object_name IS NOT NULL THEN
               p.object_owner || '.' || p.object_name ||
               CASE
                 WHEN p.object_type IS NOT NULL THEN ' [' || p.object_type || ']'
                 ELSE ''
               END ||
               CASE
                 WHEN LENGTH(TRIM(NVL(p.object_alias, ''))) > 0
                 THEN ' (' || SUBSTR(TRIM(p.object_alias), 1, 80) || ')'
                 ELSE ''
               END
             WHEN LENGTH(TRIM(NVL(p.object_alias, ''))) > 0 THEN
               SUBSTR(TRIM(p.object_alias), 1, 120)
             ELSE NULL
           END,
           1, 120
         ) AS name_txt,
         CASE
           WHEN NULLIF(TRIM(SUBSTR(p.access_predicates, 1, 200)), '') IS NOT NULL
           THEN '  -> Access: ' || SUBSTR(TRIM(SUBSTR(p.access_predicates, 1, 200)), 1, 108)
         END AS access_txt,
         CASE
           WHEN NULLIF(TRIM(SUBSTR(p.filter_predicates, 1, 200)), '') IS NOT NULL
           THEN '  -> Filter: ' || SUBSTR(TRIM(SUBSTR(p.filter_predicates, 1, 200)), 1, 108)
         END AS filter_txt,
         -- Prefer PARTITION_INFO; append PARTITION_START..STOP when non-zero
         CASE
           WHEN NULLIF(TRIM(SUBSTR(p.partition_info, 1, 200)), '') IS NOT NULL THEN
             SUBSTR(
               '  -> Partition: ' || TRIM(SUBSTR(p.partition_info, 1, 200)) ||
               CASE
                 WHEN NVL(p.partition_start, 0) <> 0 OR NVL(p.partition_stop, 0) <> 0
                 THEN ' (' || NVL(TO_CHAR(p.partition_start), '?') || '..' ||
                      NVL(TO_CHAR(p.partition_stop), '?') || ')'
                 ELSE ''
               END,
               1, 120
             )
           WHEN NVL(p.partition_start, 0) <> 0 OR NVL(p.partition_stop, 0) <> 0 THEN
             '  -> Partition: ' ||
             NVL(TO_CHAR(p.partition_start), '?') || '..' ||
             NVL(TO_CHAR(p.partition_stop), '?')
         END AS part_txt,
         CASE
           WHEN NULLIF(TRIM(SUBSTR(p.other_tag, 1, 200)), '') IS NOT NULL
           THEN '  -> Other: ' || SUBSTR(TRIM(SUBSTR(p.other_tag, 1, 200)), 1, 108)
         END AS other_txt,
         CASE
           WHEN NVL(p.temp_space, 0) <> 0
           THEN '  -> Temp: ' || TO_CHAR(p.temp_space)
         END AS temp_txt,
         CASE
           WHEN NVL(p.search_columns, 0) <> 0
           THEN '  -> SearchCols: ' || TO_CHAR(p.search_columns)
         END AS search_txt,
         CASE
           WHEN NVL(p.cpu_cost, 0) <> 0 OR NVL(p.io_cost, 0) <> 0
           THEN '  -> CpuIo: cpu=' || NVL(TO_CHAR(p.cpu_cost), '0') ||
                ' io=' || NVL(TO_CHAR(p.io_cost), '0')
         END AS cpuio_txt,
         CASE
           WHEN NULLIF(TRIM(SUBSTR(p.projection, 1, 200)), '') IS NOT NULL
           THEN '  -> Projection: ' || SUBSTR(TRIM(SUBSTR(p.projection, 1, 200)), 1, 108)
         END AS proj_txt,
         ROW_NUMBER() OVER (
           PARTITION BY p.plan_hash_value, p.id
           ORDER BY p.child_number NULLS LAST, p.child_address, p.address
         ) AS rn
    FROM v$sql_plan p
   WHERE p.sql_id = '&&sqlid'
     AND p.id IS NOT NULL
     AND p.operation IS NOT NULL
),
base AS (
  SELECT phv, id, parent_id, depth, operation, options,
         object_owner, object_name, object_type, object_alias,
         cost, cardinality, bytes, plan_time, cpu_cost, io_cost,
         search_columns, access_predicates, filter_predicates, projection,
         partition_info, partition_start, partition_stop, other_tag, temp_space,
         op_txt, name_txt, access_txt, filter_txt, part_txt, other_txt,
         temp_txt, search_txt, cpuio_txt, proj_txt
    FROM ranked
   WHERE rn = 1
),
w AS (
  SELECT phv,
         GREATEST(LENGTH('Id'), NVL(MAX(LENGTH(TO_CHAR(id))), 0)) AS w_id,
         GREATEST(LENGTH('Pid'), NVL(MAX(LENGTH(TO_CHAR(parent_id))), 0)) AS w_pid,
         GREATEST(LENGTH('Ord'), NVL(MAX(LENGTH(TO_CHAR(id))), 0)) AS w_ord,
         LEAST(
           120,
           GREATEST(
             LENGTH('Operation'),
             NVL(MAX(LENGTH(op_txt)), 0),
             NVL(MAX(LENGTH(access_txt)), 0),
             NVL(MAX(LENGTH(filter_txt)), 0),
             NVL(MAX(LENGTH(part_txt)), 0),
             NVL(MAX(LENGTH(other_txt)), 0),
             NVL(MAX(LENGTH(temp_txt)), 0),
             NVL(MAX(LENGTH(search_txt)), 0),
             NVL(MAX(LENGTH(cpuio_txt)), 0),
             NVL(MAX(LENGTH(proj_txt)), 0)
           )
         ) AS w_op,
         LEAST(120, GREATEST(LENGTH('Name'), NVL(MAX(LENGTH(name_txt)), 0))) AS w_name,
         GREATEST(LENGTH('Rows'), NVL(MAX(LENGTH(TO_CHAR(cardinality))), 0)) AS w_rows,
         GREATEST(LENGTH('Bytes'), NVL(MAX(LENGTH(TO_CHAR(bytes))), 0)) AS w_bytes,
         GREATEST(LENGTH('Cost'), NVL(MAX(LENGTH(TO_CHAR(cost))), 0)) AS w_cost,
         GREATEST(LENGTH('Time'), NVL(MAX(LENGTH(TO_CHAR(plan_time))), 0)) AS w_time
    FROM base
   GROUP BY phv
),
phvs AS (
  SELECT DISTINCT phv FROM base
),
lines AS (
  SELECT p.phv,
         0 AS sek,
         0 AS sid,
         '============================================================================' AS plan_line
    FROM phvs p
  UNION ALL
  SELECT p.phv, 1, 0,
         'Plan Hash Value: ' || TO_CHAR(p.phv)
    FROM phvs p
  UNION ALL
  SELECT p.phv, 2, 0,
         '============================================================================'
    FROM phvs p
  UNION ALL
  SELECT p.phv, 4, 0,
         '|' || LPAD('Id', w.w_id) || '|' ||
         LPAD('Pid', w.w_pid) || '|' ||
         LPAD('Ord', w.w_ord) || '|' ||
         RPAD('Operation', w.w_op) || '|' ||
         RPAD('Name', w.w_name) || '|' ||
         RPAD('Rows', w.w_rows) || '|' ||
         RPAD('Bytes', w.w_bytes) || '|' ||
         RPAD('Cost', w.w_cost) || '|' ||
         RPAD('Time', w.w_time) || '|'
    FROM phvs p
    JOIN w ON w.phv = p.phv
  UNION ALL
  SELECT p.phv, 5, 0,
         '|' || LPAD('-', w.w_id, '-') || '|' ||
         LPAD('-', w.w_pid, '-') || '|' ||
         LPAD('-', w.w_ord, '-') || '|' ||
         RPAD('-', w.w_op, '-') || '|' ||
         RPAD('-', w.w_name, '-') || '|' ||
         RPAD('-', w.w_rows, '-') || '|' ||
         RPAD('-', w.w_bytes, '-') || '|' ||
         RPAD('-', w.w_cost, '-') || '|' ||
         RPAD('-', w.w_time, '-') || '|'
    FROM phvs p
    JOIN w ON w.phv = p.phv
  UNION ALL
  SELECT b.phv, 6, b.id * 20,
         '|' || LPAD(TO_CHAR(b.id), w.w_id) || '|' ||
         LPAD(NVL(TO_CHAR(b.parent_id), ' '), w.w_pid) || '|' ||
         LPAD(TO_CHAR(b.id), w.w_ord) || '|' ||
         RPAD(SUBSTR(NVL(b.op_txt, ' '), 1, w.w_op), w.w_op) || '|' ||
         RPAD(SUBSTR(NVL(b.name_txt, ' '), 1, w.w_name), w.w_name) || '|' ||
         RPAD(SUBSTR(NVL(TO_CHAR(b.cardinality), ' '), 1, w.w_rows), w.w_rows) || '|' ||
         RPAD(SUBSTR(NVL(TO_CHAR(b.bytes), ' '), 1, w.w_bytes), w.w_bytes) || '|' ||
         RPAD(SUBSTR(NVL(TO_CHAR(b.cost), ' '), 1, w.w_cost), w.w_cost) || '|' ||
         RPAD(SUBSTR(NVL(TO_CHAR(b.plan_time), ' '), 1, w.w_time), w.w_time) || '|'
    FROM base b
    JOIN w ON w.phv = b.phv
  UNION ALL
  SELECT b.phv, 6, b.id * 20 + 1,
         '|' || LPAD(' ', w.w_id) || '|' ||
         LPAD(' ', w.w_pid) || '|' ||
         LPAD(' ', w.w_ord) || '|' ||
         RPAD(SUBSTR(b.access_txt, 1, w.w_op), w.w_op) || '|' ||
         RPAD(' ', w.w_name) || '|' ||
         RPAD(' ', w.w_rows) || '|' ||
         RPAD(' ', w.w_bytes) || '|' ||
         RPAD(' ', w.w_cost) || '|' ||
         RPAD(' ', w.w_time) || '|'
    FROM base b
    JOIN w ON w.phv = b.phv
   WHERE b.access_txt IS NOT NULL
  UNION ALL
  SELECT b.phv, 6, b.id * 20 + 2,
         '|' || LPAD(' ', w.w_id) || '|' ||
         LPAD(' ', w.w_pid) || '|' ||
         LPAD(' ', w.w_ord) || '|' ||
         RPAD(SUBSTR(b.filter_txt, 1, w.w_op), w.w_op) || '|' ||
         RPAD(' ', w.w_name) || '|' ||
         RPAD(' ', w.w_rows) || '|' ||
         RPAD(' ', w.w_bytes) || '|' ||
         RPAD(' ', w.w_cost) || '|' ||
         RPAD(' ', w.w_time) || '|'
    FROM base b
    JOIN w ON w.phv = b.phv
   WHERE b.filter_txt IS NOT NULL
  UNION ALL
  SELECT b.phv, 6, b.id * 20 + 3,
         '|' || LPAD(' ', w.w_id) || '|' ||
         LPAD(' ', w.w_pid) || '|' ||
         LPAD(' ', w.w_ord) || '|' ||
         RPAD(SUBSTR(b.part_txt, 1, w.w_op), w.w_op) || '|' ||
         RPAD(' ', w.w_name) || '|' ||
         RPAD(' ', w.w_rows) || '|' ||
         RPAD(' ', w.w_bytes) || '|' ||
         RPAD(' ', w.w_cost) || '|' ||
         RPAD(' ', w.w_time) || '|'
    FROM base b
    JOIN w ON w.phv = b.phv
   WHERE b.part_txt IS NOT NULL
  UNION ALL
  SELECT b.phv, 6, b.id * 20 + 4,
         '|' || LPAD(' ', w.w_id) || '|' ||
         LPAD(' ', w.w_pid) || '|' ||
         LPAD(' ', w.w_ord) || '|' ||
         RPAD(SUBSTR(b.other_txt, 1, w.w_op), w.w_op) || '|' ||
         RPAD(' ', w.w_name) || '|' ||
         RPAD(' ', w.w_rows) || '|' ||
         RPAD(' ', w.w_bytes) || '|' ||
         RPAD(' ', w.w_cost) || '|' ||
         RPAD(' ', w.w_time) || '|'
    FROM base b
    JOIN w ON w.phv = b.phv
   WHERE b.other_txt IS NOT NULL
  UNION ALL
  SELECT b.phv, 6, b.id * 20 + 5,
         '|' || LPAD(' ', w.w_id) || '|' ||
         LPAD(' ', w.w_pid) || '|' ||
         LPAD(' ', w.w_ord) || '|' ||
         RPAD(SUBSTR(b.temp_txt, 1, w.w_op), w.w_op) || '|' ||
         RPAD(' ', w.w_name) || '|' ||
         RPAD(' ', w.w_rows) || '|' ||
         RPAD(' ', w.w_bytes) || '|' ||
         RPAD(' ', w.w_cost) || '|' ||
         RPAD(' ', w.w_time) || '|'
    FROM base b
    JOIN w ON w.phv = b.phv
   WHERE b.temp_txt IS NOT NULL
  UNION ALL
  SELECT b.phv, 6, b.id * 20 + 6,
         '|' || LPAD(' ', w.w_id) || '|' ||
         LPAD(' ', w.w_pid) || '|' ||
         LPAD(' ', w.w_ord) || '|' ||
         RPAD(SUBSTR(b.search_txt, 1, w.w_op), w.w_op) || '|' ||
         RPAD(' ', w.w_name) || '|' ||
         RPAD(' ', w.w_rows) || '|' ||
         RPAD(' ', w.w_bytes) || '|' ||
         RPAD(' ', w.w_cost) || '|' ||
         RPAD(' ', w.w_time) || '|'
    FROM base b
    JOIN w ON w.phv = b.phv
   WHERE b.search_txt IS NOT NULL
  UNION ALL
  SELECT b.phv, 6, b.id * 20 + 7,
         '|' || LPAD(' ', w.w_id) || '|' ||
         LPAD(' ', w.w_pid) || '|' ||
         LPAD(' ', w.w_ord) || '|' ||
         RPAD(SUBSTR(b.cpuio_txt, 1, w.w_op), w.w_op) || '|' ||
         RPAD(' ', w.w_name) || '|' ||
         RPAD(' ', w.w_rows) || '|' ||
         RPAD(' ', w.w_bytes) || '|' ||
         RPAD(' ', w.w_cost) || '|' ||
         RPAD(' ', w.w_time) || '|'
    FROM base b
    JOIN w ON w.phv = b.phv
   WHERE b.cpuio_txt IS NOT NULL
  UNION ALL
  SELECT b.phv, 6, b.id * 20 + 8,
         '|' || LPAD(' ', w.w_id) || '|' ||
         LPAD(' ', w.w_pid) || '|' ||
         LPAD(' ', w.w_ord) || '|' ||
         RPAD(SUBSTR(b.proj_txt, 1, w.w_op), w.w_op) || '|' ||
         RPAD(' ', w.w_name) || '|' ||
         RPAD(' ', w.w_rows) || '|' ||
         RPAD(' ', w.w_bytes) || '|' ||
         RPAD(' ', w.w_cost) || '|' ||
         RPAD(' ', w.w_time) || '|'
    FROM base b
    JOIN w ON w.phv = b.phv
   WHERE b.proj_txt IS NOT NULL
  UNION ALL
  SELECT p.phv, 7, 0,
         '============================================================================'
    FROM phvs p
),
empty_msg AS (
  SELECT CAST(NULL AS NUMBER) AS phv,
         0 AS sek,
         0 AS sid,
         'No plan found in V$SQL_PLAN for sql_id=&&sqlid' AS plan_line
    FROM dual
   WHERE NOT EXISTS (SELECT 1 FROM base)
)
SELECT plan_line
  FROM (
        SELECT phv, sek, sid, plan_line FROM lines
        UNION ALL
        SELECT phv, sek, sid, plan_line FROM empty_msg
       )
 ORDER BY phv NULLS LAST, sek, sid
/
