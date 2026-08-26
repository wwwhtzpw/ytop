-- File Name: sequence.sql
-- Purpose: List sequences by owner and name
-- Created: 20260801 by huangtingzhong
-- Oracle ref: /Users/yihan/Documents/owner/sql/sequence.sql


col sequence_owner for a20
col sequence_name  for a30
col min_value      for a12
col max_value      for a20
col increment_by   for a10
col cycle_flag     for a5
col order_flag     for a5
col cache_size     for a10
col last_number    for a20

ACCEPT owner PROMPT 'Enter sequence owner (empty=all non-SYS/SYSTEM): '
ACCEPT name PROMPT 'Enter sequence name (empty=all): '

SELECT sequence_owner,
       sequence_name,
       TO_CHAR(min_value) AS min_value,
       TO_CHAR(max_value) AS max_value,
       TO_CHAR(increment_by) AS increment_by,
       DECODE(cycle_flag, 'Y', 'YES', 'N', 'NO', cycle_flag) AS cycle_flag,
       DECODE(order_flag, 'Y', 'YES', 'N', 'NO', order_flag) AS order_flag,
       TO_CHAR(cache_size) AS cache_size,
       TO_CHAR(last_number) AS last_number
  FROM dba_sequences
 WHERE sequence_owner = NVL(NULLIF(UPPER(TRIM('&&owner')), ''), sequence_owner)
   AND sequence_name = NVL(NULLIF(UPPER(TRIM('&&name')), ''), sequence_name)
   AND (
         NULLIF(UPPER(TRIM('&&owner')), '') IS NOT NULL
         OR sequence_owner NOT IN ('SYS', 'SYSTEM')
       )
 ORDER BY sequence_owner, sequence_name;
