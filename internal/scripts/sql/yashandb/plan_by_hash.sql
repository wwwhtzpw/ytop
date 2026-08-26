-- File Name: plan_by_hash.sql
-- Purpose: Show execution plan rows by plan_hash_value from v$sql_plan
-- Created: 20260801 by huangtingzhong
-- Updated: 20260803 by huangtingzhong
-- Oracle ref: /Users/yihan/Documents/owner/sql/plan_by_hash.sql
-- Note: uses PLAN_HASH_VALUE (Oracle old script used HASH_VALUE)
--       One row per (sql_id, PHV, id): ROW_NUMBER collapse duplicates


col sql_id   for a15
col phv      for a12
col id       for a4
col pid      for a4
col operation for a50
col object_name for a25
col cardinality for a10
col cost     for a10

ACCEPT plan_hash_value PROMPT 'Enter plan_hash_value: '
ACCEPT sqlid PROMPT 'Enter sql_id (empty=all sql_id with this PHV): '

PROMPT ===== SQL_IDs using this plan_hash_value =====
SELECT DISTINCT sql_id,
       TO_CHAR(plan_hash_value) AS phv
  FROM v$sql_plan
 WHERE plan_hash_value = TO_NUMBER(TRIM('&&plan_hash_value'))
   AND sql_id = NVL(NULLIF(TRIM('&&sqlid'), ''), sql_id)
 ORDER BY sql_id;

PROMPT ===== Plan rows (one row per sql_id+PHV+id) =====
SELECT sql_id,
       TO_CHAR(plan_hash_value) AS phv,
       TO_CHAR(id) AS id,
       TO_CHAR(parent_id) AS pid,
       LPAD(' ', NVL(depth, 0) * 2, ' ')
         || operation
         || CASE WHEN options IS NOT NULL THEN ' ' || options ELSE '' END AS operation,
       object_name,
       TO_CHAR(cardinality) AS cardinality,
       TO_CHAR(cost) AS cost
  FROM (
    SELECT p.sql_id,
           p.plan_hash_value,
           p.id,
           p.parent_id,
           p.depth,
           p.operation,
           p.options,
           p.object_name,
           p.cardinality,
           p.cost,
           ROW_NUMBER() OVER (
             PARTITION BY p.sql_id, p.plan_hash_value, p.id
             ORDER BY p.child_number NULLS LAST, p.child_address, p.address
           ) AS rn
      FROM v$sql_plan p
     WHERE p.plan_hash_value = TO_NUMBER(TRIM('&&plan_hash_value'))
       AND p.sql_id = NVL(NULLIF(TRIM('&&sqlid'), ''), p.sql_id)
       AND p.id IS NOT NULL
       AND p.operation IS NOT NULL
  )
 WHERE rn = 1
 ORDER BY sql_id, id;
