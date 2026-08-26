-- File Name: stats_table_hist.sql
-- Purpose: Show column histogram endpoints (DBA_HISTOGRAMS)
-- Created: 20260801 by huangtingzhong
--
-- Params: &&owner, &&tablename, &&columnname (empty=all columns on table)
-- Note: YashanDB view is DBA_HISTOGRAMS (not Oracle DBA_TAB_HISTOGRAMS)
-- Note: histogram type may show as FREQUENCE (Yashan spelling)
-- Note: numeric endpoint_value (incl. scientific E+/-) shown as plain decimal


col o_t          for a28
col column_name  for a20
col ep_num       for a8
col differ       for a14
col ep_value     for a36
col ep_repeat    for a8
col histogram    for a12

ACCEPT owner PROMPT 'Enter table owner (e.g. HTZ): '
ACCEPT tablename PROMPT 'Enter table name (e.g. PART): '
ACCEPT columnname PROMPT 'Enter column name (empty=all columns with hist): '

SELECT h.owner || '.' || h.table_name AS o_t,
       h.column_name,
       TO_CHAR(h.endpoint_number) AS ep_num,
       CASE
         WHEN s.histogram IN ('FREQUENCY', 'FREQUENCE') THEN
           TO_CHAR(
             h.endpoint_number
             - LAG(h.endpoint_number, 1, 0)
                 OVER (
                   PARTITION BY h.owner, h.table_name, h.column_name
                   ORDER BY h.endpoint_number
                 )
           )
         WHEN s.histogram = 'HEIGHT BALANCED' THEN 'HEIGHT BALANCED'
         ELSE NVL(s.histogram, 'NONE')
       END AS differ,
       SUBSTR(
         CASE
           WHEN REGEXP_LIKE(
                  TRIM(h.endpoint_value),
                  '^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([Ee][+-]?[0-9]+)?$'
                )
           THEN RTRIM(
                  RTRIM(
                    TO_CHAR(
                      TO_NUMBER(TRIM(h.endpoint_value)),
                      'FM999999999999999999990.999999999999999999'
                    ),
                    '0'
                  ),
                  '.'
                )
           ELSE h.endpoint_value
         END,
         1,
         36
       ) AS ep_value,
       TO_CHAR(h.endpoint_repeat_count) AS ep_repeat,
       s.histogram
  FROM dba_histograms h, dba_tab_col_statistics s
 WHERE h.owner = UPPER(TRIM('&&owner'))
   AND h.table_name = UPPER(TRIM('&&tablename'))
   AND h.column_name = NVL(NULLIF(UPPER(TRIM('&&columnname')), ''), h.column_name)
   AND h.owner = s.owner
   AND h.table_name = s.table_name
   AND h.column_name = s.column_name
 ORDER BY o_t, h.column_name, h.endpoint_number;
