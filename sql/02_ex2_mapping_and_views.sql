-- =====================================================================
-- 02_ex2_mapping_and_views.sql  Exercise 2：共通機種IDで統合する（20分）
-- 方針 : 元システムのデータは一切変更しない。対応関係は Databricks 側の Delta 表で管理する。
--        確定的な集計に使うのは approval_status = 'APPROVED' の対応だけ。
-- =====================================================================
-- 💡 なぜ：対応関係を Databricks 側の表で管理し、元システムを変えずに、計画・販売・生産をつなぎます。
-- 💡 仕組み：確定対応（APPROVED）だけを使う View を作り、実績や計画の各行に共通機種IDを付けます。View なので、対応表を更新すれば結果も自動で変わります。
-- @config-begin  ノートブック版では 00_config がカタログ・スキーマを設定するため、この範囲は自動で除去されます
USE CATALOG workspace;             -- ★ SQL エディタで実行する場合は config/00_config と同じ値にする
USE SCHEMA vehicle_alias_handson;  -- ★ 同上
-- @config-end

-- @notebook-replace-begin notebook_snippets/02_ingest_history_excel.py
-- ---------------------------------------------------------------------
-- 2-0. （SQL エディタ版）過去の人手承認履歴を Volume から取り込む
--   ノートブック版では、この範囲は Excel（data/alias_mapping_history.xlsx）を取り込むセルに置き換わる。
--   SQL エディタでは、同じ内容の CSV（data/alias_mapping_history.csv）を read_files で取り込む。
-- ---------------------------------------------------------------------
-- 💡 なぜ：人手で作った対応履歴のファイルを、Unity Catalog の Volume に置いてから取り込みます。置き場所・権限・取り込み元の記録を1か所にそろえるためです。
-- 💡 仕組み：`read_files` は、Volume などに置いたファイルを表として読む関数です。`inferColumnTypes => false` で全列を文字列として読み、`try_to_date` で日付に変換します（空欄や不正な値は NULL）。`_metadata.file_path` で取り込み元のファイルを記録します。
-- 💡 利点：ノートブック版（Excel）と同じ列・同じ内容のテーブルができるので、以降の手順はどちらで取り込んでも同じです。
CREATE VOLUME IF NOT EXISTS handson_files
COMMENT 'ハンズオン用の元ファイル置き場（人手で作成した対応履歴など・架空データ）';

-- ★ ここで data/alias_mapping_history.csv を、カタログ → スキーマ → ボリューム handson_files にアップロードしてから次を実行
--   パスの workspace / vehicle_alias_handson は、自分のカタログ・スキーマに変更する
CREATE OR REPLACE TABLE alias_mapping_history
COMMENT '過去の人手対応履歴（架空）。Volume のファイル（source_file）から取り込んだもの。確定マスタではない。'
AS
SELECT
  `履歴ID`                            AS history_id,
  `元システム`                        AS source_system,
  `国`                                AS country,
  `業務領域`                          AS business_area,
  nullif(trim(`元の名称`), '')        AS source_name,
  nullif(trim(`元のコード`), '')      AS source_code,
  nullif(trim(`対応づけた共通機種ID`), '') AS mapped_vehicle_id,
  try_to_date(nullif(`適用開始日`, '')) AS valid_from,
  try_to_date(nullif(`適用終了日`, '')) AS valid_to,
  `状態`                              AS history_status,
  `承認部署`                          AS approved_by,
  try_to_date(nullif(`承認日`, ''))   AS approved_at,
  `元資料`                            AS source_document,
  _metadata.file_path                 AS source_file,
  current_timestamp()                 AS ingested_at
FROM read_files('/Volumes/workspace/vehicle_alias_handson/handson_files/alias_mapping_history.csv',
                format => 'csv', header => true, inferColumnTypes => false);

SELECT * FROM alias_mapping_history ORDER BY history_id;
-- @notebook-replace-end

-- ---------------------------------------------------------------------
-- 2-1. 正規化関数の動作確認
-- ---------------------------------------------------------------------
-- 💡 なぜ：正規化関数が表記揺れをどうそろえるか、どこから先はそろえないか（簡体字と繁体字）を先に確かめます。
-- 💡 仕組み：`VALUES` 句でその場限りの表を作り、関数を試します。
SELECT raw, norm_code(raw) AS code_normalized, norm_name(raw) AS name_normalized
FROM VALUES ('JP-A11'), ('jp-a11 '), ('ＪＰ－Ａ１１'), ('MTO-987'), ('mto-987 '),
            ('ALPHA 11 M'), ('Ａｌｐｈａ　１１Ｍ'), ('阿尔法'), ('阿爾法') AS t(raw);

-- ---------------------------------------------------------------------
-- 2-2. 【Before】確定マスタの「完全一致」だけで変換した場合のカバー率
-- ---------------------------------------------------------------------
-- 💡 なぜ：完全一致だけで、どこまで変換できるか（Before）を数字で押さえます。
-- 💡 仕組み：`LEFT JOIN` で、対応表に一致しなかった行も残し、一致した行の割合を計算します。適用期間（`BETWEEN valid_from AND valid_to`）も条件に入れています。
-- 💡 利点：後でルールを足したときの改善を、同じ指標で比べられます。
SELECT
  count(*)                                         AS sales_rows,
  count(a.alias_id)                                AS matched_rows,
  round(count(a.alias_id) / count(*) * 100, 1)     AS match_rate_pct
FROM sales_actual s
LEFT JOIN vehicle_alias_master a
  ON a.approval_status = 'APPROVED'
 AND a.business_area   = 'SALES'
 AND a.local_vehicle_code = s.sales_vehicle_code
 AND s.sales_month BETWEEN a.valid_from AND a.valid_to;
-- 期待値（2-4 の MERGE 実行前）: 26 行中 18 行（69.2%）。
--   落ちる 8 行 = 表記揺れ 2行（S006, S009）・旧中国コード 2行（S013, S014）・候補のみ/未登録 4行（S023〜S026）
--   ※ 2-4 実行後に再実行すると S013, S014 が一致し 20 行（76.9%）になる

-- ---------------------------------------------------------------------
-- 2-3. 名称の表記揺れを正規化して、名称のみの過去履歴を確認する
--       → 候補が 1つに絞れるものと、複数候補（要確認）になるものがある
-- ---------------------------------------------------------------------
-- 💡 なぜ：コードが無く名称だけの履歴は、名称を正規化して照合するしかありません。ただし、候補が複数ある場合は自動で決めずに要確認にします。
-- 💡 仕組み：`collect_set` で候補の共通機種IDを重複なしで集め、`size` で数を数えて判定します。
-- 💡 利点：名称だけの情報でも、使える部分（一意に決まるもの）と、人が見るべき部分を分けられます。
SELECT
  h.history_id,
  h.source_name,
  norm_name(h.source_name)                          AS normalized_name,
  array_sort(collect_set(a.canonical_vehicle_id))   AS candidate_vehicle_ids,
  CASE size(collect_set(a.canonical_vehicle_id))
    WHEN 0 THEN '未解決（名称が一致しない。簡体字/繁体字など辞書が必要）'
    WHEN 1 THEN '一意に特定（ただしコード・期間で最終確認）'
    ELSE        '要確認（同名の別世代・別機種が存在）'
  END                                               AS judgement
FROM alias_mapping_history h
LEFT JOIN vehicle_alias_master a
  ON a.approval_status = 'APPROVED'
 AND norm_name(a.local_vehicle_name) = norm_name(h.source_name)
WHERE h.source_code IS NULL
GROUP BY h.history_id, h.source_name
ORDER BY h.history_id;
-- 期待値: H002/H003 → [VEHICLE-001]、H004 'alpha' → [VEHICLE-001, VEHICLE-002]（要確認）、H005 '阿爾法' → 未解決

-- ---------------------------------------------------------------------
-- 2-4. 過去の人手承認履歴（コードあり・APPROVED）を対応表に取り込む
--       元の Excel は変更しない。取込元・承認者・根拠資料を残す。
-- ---------------------------------------------------------------------
-- 💡 なぜ：人手で承認済みで、コードと適用期間がある履歴だけを、確定対応として対応表に取り込みます。元の Excel は変更しません。
-- 💡 仕組み：`MERGE INTO` は、キー（alias_id）が一致すれば更新し、無ければ追加する命令です。何度実行しても結果が同じ（べき等）になります。
-- 💡 利点：`mapping_method` を HISTORY にし、`source_document` と `approved_by` に元資料と承認部署を残すので、なぜ確定としたかを後から説明できます。
MERGE INTO vehicle_alias_master AS t
USING (
  SELECT
    concat('HIST-', history_id)  AS alias_id,
    mapped_vehicle_id            AS canonical_vehicle_id,
    country,
    business_area,
    source_name                  AS local_vehicle_name,
    source_code                  AS local_vehicle_code,
    valid_from,
    valid_to,
    'APPROVED'                   AS approval_status,
    97                           AS confidence_score,
    'HISTORY'                    AS mapping_method,
    source_document,
    approved_by,
    concat('過去の人手対応履歴から取込（承認日 ', CAST(approved_at AS STRING), '）') AS remarks,
    current_timestamp()          AS updated_at
  FROM alias_mapping_history
  WHERE history_status = 'APPROVED'
    AND source_code IS NOT NULL
    AND mapped_vehicle_id IS NOT NULL
    AND valid_from IS NOT NULL AND valid_to IS NOT NULL
) AS s
ON t.alias_id = s.alias_id
WHEN MATCHED THEN UPDATE SET *
WHEN NOT MATCHED THEN INSERT *;

-- 💡 なぜ：取り込まれた行を確認します。
SELECT * FROM vehicle_alias_master WHERE mapping_method = 'HISTORY';
-- 期待値: HIST-H001（CN-X123B → VEHICLE-001、2024-07-01〜2025-05-31）

-- ---------------------------------------------------------------------
-- 2-5. 確定済み対応（APPROVED かつ必須項目あり）の View
-- ---------------------------------------------------------------------
-- 💡 なぜ：集計に使ってよい対応を「APPROVED かつ必須項目あり」に限る、ただ1つの入り口を作ります。
-- 💡 仕組み：View は SQL の定義だけを保存し、参照するたびに元のテーブルから計算します。正規化済みのコードもここで計算しておきます。
-- 💡 利点：候補や登録途中の行が、うっかり集計に混ざることを防げます。
CREATE OR REPLACE VIEW v_alias_approved
COMMENT '確定済みの名称・コード対応。集計に使用してよいのはこの View の対応のみ。'
AS
SELECT
  alias_id, canonical_vehicle_id, country, business_area,
  local_vehicle_name, local_vehicle_code,
  norm_code(local_vehicle_code) AS norm_vehicle_code,
  valid_from, valid_to, confidence_score, mapping_method, source_document
FROM vehicle_alias_master
WHERE approval_status = 'APPROVED'
  AND canonical_vehicle_id IS NOT NULL
  AND local_vehicle_code   IS NOT NULL
  AND valid_from IS NOT NULL
  AND valid_to   IS NOT NULL;

-- ---------------------------------------------------------------------
-- 2-6. 各実績・計画レコードを共通機種IDへ変換する View
--   ルール:
--   (1) 業務領域（SALES / PRODUCTION / DEVELOPMENT）が一致すること（同じ文字列でも別システムなら別物）
--   (2) 正規化後のコードが一致すること
--   (3) レコードの月が適用期間内であること
--   (4) 候補が 1つの共通機種IDに絞れること。2つ以上なら CONFLICT として集計から除外（誤結合より要確認を優先）
-- ---------------------------------------------------------------------
-- 💡 なぜ：販売実績の各行に共通機種IDを付けます。4つの条件（業務領域・正規化したコード・適用期間・一意性）をすべて満たす場合だけ変換します。
-- 💡 仕組み：`LEFT JOIN` で候補をすべてつないだ後、行ごとに `GROUP BY` します。共通機種IDが1つなら RESOLVED、0なら UNRESOLVED、2つ以上なら CONFLICT とします。
-- 💡 利点：別の車両の数字が誤って混ざるより、変換せずに要確認として残す設計になります。どのルールで変換したか（`resolution_method`）も残ります。
CREATE OR REPLACE VIEW v_sales_resolved
COMMENT '販売実績に共通機種IDを付与した View（RESOLVED / UNRESOLVED / CONFLICT）'
AS
WITH matched AS (
  SELECT s.*, a.canonical_vehicle_id, a.alias_id,
         CASE WHEN a.alias_id IS NULL THEN NULL
              WHEN s.sales_vehicle_code = a.local_vehicle_code THEN concat('EXACT:', a.mapping_method)
              ELSE concat('NORMALIZED:', a.mapping_method) END AS method
  FROM sales_actual s
  LEFT JOIN v_alias_approved a
    ON a.business_area     = 'SALES'
   AND a.country           = s.country
   AND a.norm_vehicle_code = norm_code(s.sales_vehicle_code)
   AND s.sales_month BETWEEN a.valid_from AND a.valid_to
)
SELECT
  sales_record_id, country, sales_vehicle_code, powertrain, body_type,
  sales_month, sales_volume, actual_sales, source_system,
  CASE WHEN count(DISTINCT canonical_vehicle_id) = 1 THEN max(canonical_vehicle_id) END AS canonical_vehicle_id,
  CASE WHEN count(DISTINCT canonical_vehicle_id) = 0 THEN 'UNRESOLVED'
       WHEN count(DISTINCT canonical_vehicle_id) > 1 THEN 'CONFLICT'
       ELSE 'RESOLVED' END                                   AS resolution_status,
  nullif(concat_ws(',', array_sort(collect_set(method))), '')   AS resolution_method,
  nullif(concat_ws(',', array_sort(collect_set(alias_id))), '') AS alias_ids
FROM matched
GROUP BY sales_record_id, country, sales_vehicle_code, powertrain, body_type,
         sales_month, sales_volume, actual_sales, source_system;

-- 💡 なぜ：生産実績も、販売と同じ4つの条件で変換します。業務領域（PRODUCTION）で分けるので、同じ文字列のコードがあっても販売とは混ざりません。
CREATE OR REPLACE VIEW v_production_resolved
COMMENT '生産実績に共通機種IDを付与した View（RESOLVED / UNRESOLVED / CONFLICT）'
AS
WITH matched AS (
  SELECT p.*, a.canonical_vehicle_id, a.alias_id,
         CASE WHEN a.alias_id IS NULL THEN NULL
              WHEN p.mto_code = a.local_vehicle_code THEN concat('EXACT:', a.mapping_method)
              ELSE concat('NORMALIZED:', a.mapping_method) END AS method
  FROM production_actual p
  LEFT JOIN v_alias_approved a
    ON a.business_area     = 'PRODUCTION'
   AND a.norm_vehicle_code = norm_code(p.mto_code)
   AND p.production_month BETWEEN a.valid_from AND a.valid_to
)
SELECT
  production_record_id, plant_code, mto_code, production_month,
  production_volume, actual_material_cost,
  CASE WHEN count(DISTINCT canonical_vehicle_id) = 1 THEN max(canonical_vehicle_id) END AS canonical_vehicle_id,
  CASE WHEN count(DISTINCT canonical_vehicle_id) = 0 THEN 'UNRESOLVED'
       WHEN count(DISTINCT canonical_vehicle_id) > 1 THEN 'CONFLICT'
       ELSE 'RESOLVED' END                                   AS resolution_status,
  nullif(concat_ws(',', array_sort(collect_set(method))), '')   AS resolution_method,
  nullif(concat_ws(',', array_sort(collect_set(alias_id))), '') AS alias_ids
FROM matched
GROUP BY production_record_id, plant_code, mto_code, production_month,
         production_volume, actual_material_cost;

-- 💡 なぜ：開発計画にも、同じ仕組みで共通機種IDを付けます。3つの系統が同じ ID を持つことで、初めて横断して集計できます。
CREATE OR REPLACE VIEW v_plan_resolved
COMMENT '開発計画に共通機種IDを付与した View（RESOLVED / UNRESOLVED / CONFLICT）'
AS
WITH matched AS (
  SELECT d.*, a.canonical_vehicle_id, a.alias_id,
         CASE WHEN a.alias_id IS NULL THEN NULL
              WHEN d.development_vehicle_code = a.local_vehicle_code THEN concat('EXACT:', a.mapping_method)
              ELSE concat('NORMALIZED:', a.mapping_method) END AS method
  FROM development_plan d
  LEFT JOIN v_alias_approved a
    ON a.business_area     = 'DEVELOPMENT'
   AND a.norm_vehicle_code = norm_code(d.development_vehicle_code)
   AND d.plan_month BETWEEN a.valid_from AND a.valid_to
)
SELECT
  plan_record_id, development_vehicle_code, plan_year, plan_month, plan_version,
  planned_volume, planned_material_cost, planned_sales,
  CASE WHEN count(DISTINCT canonical_vehicle_id) = 1 THEN max(canonical_vehicle_id) END AS canonical_vehicle_id,
  CASE WHEN count(DISTINCT canonical_vehicle_id) = 0 THEN 'UNRESOLVED'
       WHEN count(DISTINCT canonical_vehicle_id) > 1 THEN 'CONFLICT'
       ELSE 'RESOLVED' END                                   AS resolution_status,
  nullif(concat_ws(',', array_sort(collect_set(method))), '')   AS resolution_method,
  nullif(concat_ws(',', array_sort(collect_set(alias_id))), '') AS alias_ids
FROM matched
GROUP BY plan_record_id, development_vehicle_code, plan_year, plan_month, plan_version,
         planned_volume, planned_material_cost, planned_sales;

-- 変換結果の内訳（どのルールで解決したか）
-- 💡 なぜ：どのルール（完全一致・正規化・過去の履歴）で何行を救えたかを確かめます。
-- 💡 利点：対応表の改善が、どの工程の手作業を減らしたかを説明する材料になります。
SELECT 'SALES' AS area, resolution_status, resolution_method, count(*) AS rows, sum(sales_volume) AS volume
FROM v_sales_resolved GROUP BY ALL
UNION ALL
SELECT 'PRODUCTION', resolution_status, resolution_method, count(*), sum(production_volume)
FROM v_production_resolved GROUP BY ALL
UNION ALL
SELECT 'DEVELOPMENT', resolution_status, resolution_method, count(*), sum(planned_volume)
FROM v_plan_resolved GROUP BY ALL
ORDER BY area, resolution_status, resolution_method;

-- ---------------------------------------------------------------------
-- 2-7. 車種別採算分析用 View（共通機種ID × 月で計画・販売・生産を横断）
--   注意: 粒度を揃えてから結合する（各系を 共通機種ID × 月 に集約してから JOIN）。
--         集約前に JOIN すると行が掛け算で増え、金額が重複計上される。
-- ---------------------------------------------------------------------
-- 💡 なぜ：計画・販売・生産を「共通機種ID × 月」でそろえて並べ、採算を見られるようにします。
-- 💡 仕組み：3つの系統を、それぞれ「共通機種ID × 月」に集計してから結合します（明細のまま結合すると行が掛け算で増え、金額が重複するため）。すべての組み合わせ（`keys`）を `UNION` で作ってから `LEFT JOIN` するので、どれかの系統にしか無い月も落ちません。
-- 💡 利点：1台あたりの材料費など、系統をまたいだ指標を正しく計算できます。
CREATE OR REPLACE VIEW v_vehicle_monthly_profitability
COMMENT '車種別採算分析用 View。共通機種ID × 月で計画・販売・生産を横断集計（金額: 百万円・架空）。RESOLVED のレコードのみ集計。'
AS
WITH plan AS (
  SELECT canonical_vehicle_id, plan_month AS month,
         sum(planned_volume) AS planned_volume,
         sum(planned_material_cost) AS planned_material_cost,
         sum(planned_sales) AS planned_sales
  FROM v_plan_resolved WHERE resolution_status = 'RESOLVED' GROUP BY ALL
), sales AS (
  SELECT canonical_vehicle_id, sales_month AS month,
         sum(sales_volume) AS sales_volume,
         sum(actual_sales) AS actual_sales
  FROM v_sales_resolved WHERE resolution_status = 'RESOLVED' GROUP BY ALL
), prod AS (
  SELECT canonical_vehicle_id, production_month AS month,
         sum(production_volume) AS production_volume,
         sum(actual_material_cost) AS actual_material_cost
  FROM v_production_resolved WHERE resolution_status = 'RESOLVED' GROUP BY ALL
), keys AS (
  SELECT canonical_vehicle_id, month FROM plan
  UNION SELECT canonical_vehicle_id, month FROM sales
  UNION SELECT canonical_vehicle_id, month FROM prod
)
SELECT
  k.canonical_vehicle_id,
  v.global_vehicle_name,
  k.month,
  plan.planned_volume,
  sales.sales_volume,
  prod.production_volume,
  plan.planned_sales,
  sales.actual_sales,
  sales.actual_sales - plan.planned_sales                           AS sales_variance,
  plan.planned_material_cost,
  prod.actual_material_cost,
  prod.actual_material_cost - plan.planned_material_cost            AS material_cost_variance,
  round(plan.planned_material_cost / nullif(plan.planned_volume, 0), 3)      AS planned_cost_per_unit,
  round(prod.actual_material_cost  / nullif(prod.production_volume, 0), 3)   AS actual_cost_per_unit
FROM keys k
LEFT JOIN plan  USING (canonical_vehicle_id, month)
LEFT JOIN sales USING (canonical_vehicle_id, month)
LEFT JOIN prod  USING (canonical_vehicle_id, month)
LEFT JOIN canonical_vehicle v ON v.canonical_vehicle_id = k.canonical_vehicle_id;

-- ドメインタグ（Domains UI が使えない場合の代替・検索性向上）
-- 💡 なぜ：View にもドメインのタグを付け、業務のまとまりとして検索できるようにします。
ALTER VIEW v_vehicle_monthly_profitability SET TAGS ('handson_business_domain' = 'Vehicle Profitability', 'data_role' = 'analytics');

-- ---------------------------------------------------------------------
-- 2-8. 結果確認：Model Alpha 11th Gen（VEHICLE-001）の月次採算
-- ---------------------------------------------------------------------
-- 💡 なぜ：結果を期待値と照らし合わせます。8月の材料費が突出していることも確認します。
SELECT month, planned_volume, sales_volume, production_volume,
       planned_sales, actual_sales, sales_variance,
       planned_material_cost, actual_material_cost, material_cost_variance,
       planned_cost_per_unit, actual_cost_per_unit
FROM v_vehicle_monthly_profitability
WHERE canonical_vehicle_id = 'VEHICLE-001'
ORDER BY month;
-- 期待値（抜粋）: 2025-08 実績材料費 7,150 / 計画 6,660 / 差額 +490（最大）
--               6か月合計 計画材料費 39,060 / 実績材料費 38,730 / 差額 -330

-- 2-9. 集計から除外されたレコード（次の Exercise 5 で扱う）
-- 💡 なぜ：集計から外したデータを隠さず、一覧にします。どれだけの金額が集計に入っていないかを、後で経営者にも示せるようにするためです。
-- 💡 仕組み：3つの変換 View から、RESOLVED 以外の行を `UNION ALL` でまとめます。
CREATE OR REPLACE VIEW v_unresolved_records
COMMENT '共通機種IDに変換できず集計から除外されたレコード（UNRESOLVED / CONFLICT）'
AS
SELECT 'SALES' AS business_area, sales_record_id AS record_id, country, sales_vehicle_code AS source_code,
       sales_month AS month, sales_volume AS volume, actual_sales AS amount, 'actual_sales' AS amount_type, resolution_status
FROM v_sales_resolved WHERE resolution_status <> 'RESOLVED'
UNION ALL
SELECT 'PRODUCTION', production_record_id, 'JP', mto_code,
       production_month, production_volume, actual_material_cost, 'actual_material_cost', resolution_status
FROM v_production_resolved WHERE resolution_status <> 'RESOLVED'
UNION ALL
SELECT 'DEVELOPMENT', plan_record_id, 'GLOBAL', development_vehicle_code,
       plan_month, planned_volume, planned_material_cost, 'planned_material_cost', resolution_status
FROM v_plan_resolved WHERE resolution_status <> 'RESOLVED';

-- 💡 なぜ：除外されたレコードを確認します。Exercise 5 で、これを分類します。
SELECT * FROM v_unresolved_records ORDER BY business_area, record_id;
-- 期待値: 販売 4行（CN-X12 / JP-A11-SE / TH-Z999 / KR-Q777）、生産 2行（MTO-988 UNRESOLVED / MTO-990 CONFLICT）
