-- =====================================================================
-- 06_ex6_data_quality.sql  Exercise 6：データ品質問題を検出する（10分）
-- 方針 : 品質判定は LLM ではなく、SQL / データ品質ルールで決定的に行う。
--        同じデータに対しては何度実行しても同じ結果になり、監査・再現が可能。
-- =====================================================================
-- @config-begin  ノートブック版では 00_config がカタログ・スキーマを設定するため、この範囲は自動で除去されます
USE CATALOG workspace;             -- ★ SQL エディタで実行する場合は config/00_config と同じ値にする
USE SCHEMA vehicle_alias_handson;  -- ★ 同上
-- @config-end

-- DQ-1. 1台当たりのタイヤ数量が想定値 4 を超えている MTO
SELECT mto_code,
       sum(quantity_per_vehicle)                     AS tire_qty_per_vehicle,
       count(*)                                      AS bom_lines,
       collect_list(concat(bom_line_id, '(rev ', bom_revision, ': ', quantity_per_vehicle, ')')) AS lines
FROM vehicle_bom
WHERE part_category = 'TIRE'
GROUP BY mto_code
HAVING sum(quantity_per_vehicle) > 4;
-- 期待値: MTO-987 = 6本（B003 rev B: 4 ＋ B004 rev A: 2。旧版の残存）

-- DQ-2. 同一 MTO 内で同一部品が複数行存在する（重複・旧版残存）
SELECT mto_code, part_code, part_name,
       count(*)                       AS line_count,
       sum(quantity_per_vehicle)      AS total_qty,
       collect_list(bom_line_id)      AS bom_line_ids,
       collect_set(bom_revision)      AS revisions
FROM vehicle_bom
GROUP BY mto_code, part_code, part_name
HAVING count(*) > 1;
-- 期待値: MTO-987 × TR-225-55R18（B003, B004）、MTO-987 × BT-12V（B006, B007）

-- DQ-3. 同一の元コードに、期間が重なる複数の「有効な」共通機種IDが存在する
SELECT a.business_area, a.local_vehicle_code,
       a.alias_id AS alias_id_1, a.canonical_vehicle_id AS vehicle_1,
       b.alias_id AS alias_id_2, b.canonical_vehicle_id AS vehicle_2,
       greatest(a.valid_from, b.valid_from) AS overlap_from,
       least(a.valid_to, b.valid_to)        AS overlap_to
FROM v_alias_approved a
JOIN v_alias_approved b
  ON a.business_area     = b.business_area
 AND a.norm_vehicle_code = b.norm_vehicle_code
 AND coalesce(a.country, '') = coalesce(b.country, '')
 AND a.alias_id < b.alias_id
 AND a.canonical_vehicle_id <> b.canonical_vehicle_id
 AND a.valid_from <= b.valid_to
 AND b.valid_from <= a.valid_to;
-- 期待値: PRODUCTION × MTO-990（A012 → VEHICLE-001 / A013 → VEHICLE-003）

-- DQ-4. 必須コード・適用期間の欠損、期間の逆転
SELECT alias_id, canonical_vehicle_id, business_area, local_vehicle_name, local_vehicle_code,
       valid_from, valid_to, approval_status,
       concat_ws(', ',
         CASE WHEN canonical_vehicle_id IS NULL THEN '共通機種ID欠損' END,
         CASE WHEN local_vehicle_code   IS NULL THEN '機種コード欠損' END,
         CASE WHEN valid_from IS NULL           THEN '適用開始日欠損' END,
         CASE WHEN valid_to   IS NULL           THEN '適用終了日欠損' END,
         CASE WHEN valid_from > valid_to        THEN '適用期間が逆転' END) AS issues
FROM vehicle_alias_master
WHERE canonical_vehicle_id IS NULL OR local_vehicle_code IS NULL
   OR valid_from IS NULL OR valid_to IS NULL OR valid_from > valid_to;
-- 期待値: A019（Alpha Service：機種コード・適用開始日・適用終了日が欠損）

-- DQ-5. 実績コードの対応表カバー率（未解決の割合を KPI として監視）
SELECT business_area,
       count(*)                                                        AS records,
       count_if(resolution_status = 'RESOLVED')                        AS resolved,
       round(count_if(resolution_status = 'RESOLVED') / count(*) * 100, 1) AS resolved_pct
FROM (
  SELECT 'SALES' AS business_area, resolution_status FROM v_sales_resolved
  UNION ALL SELECT 'PRODUCTION', resolution_status FROM v_production_resolved
  UNION ALL SELECT 'DEVELOPMENT', resolution_status FROM v_plan_resolved
)
GROUP BY business_area;

-- ---------------------------------------------------------------------
-- DQ サマリ View（ダッシュボード・Genie から参照）
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_dq_summary
COMMENT 'データ品質ルールの違反件数サマリ（SQL ルールによる決定的な判定）'
AS
SELECT 'DQ-1' AS rule_id, 'タイヤ数量が1台当たり4本を超過' AS rule_name, 'HIGH' AS severity,
       (SELECT count(*) FROM (SELECT mto_code FROM vehicle_bom WHERE part_category = 'TIRE'
                              GROUP BY mto_code HAVING sum(quantity_per_vehicle) > 4)) AS violations
UNION ALL
SELECT 'DQ-2', '同一MTO内の同一部品重複', 'HIGH',
       (SELECT count(*) FROM (SELECT mto_code, part_code FROM vehicle_bom
                              GROUP BY mto_code, part_code HAVING count(*) > 1))
UNION ALL
SELECT 'DQ-3', '同一元コードに複数の有効な共通機種ID', 'HIGH',
       (SELECT count(*) FROM v_alias_approved a JOIN v_alias_approved b
          ON a.business_area = b.business_area AND a.norm_vehicle_code = b.norm_vehicle_code
         AND coalesce(a.country, '') = coalesce(b.country, '')
         AND a.alias_id < b.alias_id AND a.canonical_vehicle_id <> b.canonical_vehicle_id
         AND a.valid_from <= b.valid_to AND b.valid_from <= a.valid_to)
UNION ALL
SELECT 'DQ-4', '必須コード・適用期間の欠損/逆転', 'MEDIUM',
       (SELECT count(*) FROM vehicle_alias_master
         WHERE canonical_vehicle_id IS NULL OR local_vehicle_code IS NULL
            OR valid_from IS NULL OR valid_to IS NULL OR valid_from > valid_to)
UNION ALL
SELECT 'DQ-5', '共通機種IDに変換できない実績・計画レコード', 'MEDIUM',
       (SELECT count(*) FROM v_unresolved_records);

SELECT * FROM v_dq_summary ORDER BY rule_id;
-- 期待値（Exercise 5 で A014 を承認した後）: DQ-1=1, DQ-2=2, DQ-3=1, DQ-4=1, DQ-5=5

-- ---------------------------------------------------------------------
-- （参考）Delta の CHECK 制約で「今後の不正入力」を書き込み時に拒否する
--   既存データが違反している制約は追加できない → まず上記 DQ で既存データを是正する必要があることを確認
-- ---------------------------------------------------------------------
ALTER TABLE vehicle_bom DROP CONSTRAINT IF EXISTS qty_positive;   -- 再実行できるように一度削除
ALTER TABLE vehicle_bom ADD CONSTRAINT qty_positive CHECK (quantity_per_vehicle > 0);   -- 成功する

-- 次は既存データ（A019：機種コード NULL）が違反しているため失敗する（エラーになることを確認する）
-- @expect-error
ALTER TABLE vehicle_alias_master ADD CONSTRAINT code_required CHECK (local_vehicle_code IS NOT NULL);

-- 制約違反の書き込みが拒否されることを確認（数量 0 は qty_positive 違反で失敗する）
-- @expect-error
INSERT INTO vehicle_bom VALUES ('B999','MTO-987','TIRE','TR-X','テスト',0,'B','TEST',current_timestamp());
